#!/bin/sh
# CLUSTER_NAME
# DATA_DIR
# COMMIT_LOG_DIR
# LISTEN_ADDRESS
# MULTI_REGION
# INITIAL_SEEDS_LIST

# http://docs.datastax.com/en/cassandra/2.0/cassandra/architecture/architectureGossipAbout_c.html
# "...it is recommended to use a small seed list (approximately three nodes per data center)."
NEEDED_SEEDS=${NEEDED_SEEDS:-$((CLUSTER_SIZE > 3 ? 3 : 1))}
TTL=${TTL:-30}

if [ -z "$ETCD_URL" ] ;
then
    echo "etcd URL is not defined."
    exit 1
fi
echo "Using $ETCD_URL to access etcd ..."

if [ -z "$CLUSTER_NAME" ] ;
then
    echo "Cluster name is not defined."
    exit 1
fi

if [ -z "$LISTEN_ADDRESS" ] ;
then
    export LISTEN_ADDRESS=$(curl -Ls -m 4 http://169.254.169.254/latest/meta-data/local-ipv4)
fi
echo "Node private IP address is $LISTEN_ADDRESS ..."

if [ -z "$BROADCAST_ADDRESS" -a "$MULTI_REGION" != "0" ] ;
then
    export BROADCAST_ADDRESS=$(curl -Ls -m 4 http://169.254.169.254/latest/meta-data/public-ipv4)
fi
if [ -n "$BROADCAST_ADDRESS" ] ;
then
    echo "Node public IP address is $BROADCAST_ADDRESS ..."
fi

if [ -z $SNITCH ] ;
then
    if [ "$MULTI_REGION" != "0" ] ;
    then
        export SNITCH="Ec2MultiRegionSnitch"
    else
        export SNITCH="Ec2Snitch"
    fi
fi

if [ -z "$OPSCENTER" ] ;
then
    export OPSCENTER=$(curl -Ls -m 4 ${ETCD_URL}/v2/keys/cassandra/opscenter | jq -r '.node.value')
fi

export DATA_DIR=${DATA_DIR:-/var/cassandra/data}
export COMMIT_LOG_DIR=${COMMIT_LOG_DIR:-/var/cassandra/data/commit_logs}
            
curl -s "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/size?prevExist=false" \
    -XPUT -d value=${CLUSTER_SIZE} > /dev/null

if [ -n "$BACKUP_BUCKET" ] ;
then 
    curl -s "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/snapshot_pattern/" \
      -XPUT -d value='05 ?' > /dev/null        
fi

if [ -n "$INITIAL_SEEDS_LIST" ] ;
then
    echo "$INITIAL_SEEDS_LIST" | tr ' ' '\n' | while read seed_address; do
        echo "Injecting into initial seeds list: ${seed_address} ..."
        curl -Lsf "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/seeds" \
             -XPOST -d value=${seed_address} > /dev/null
    done
fi

while true; do 
    curl -Lsf "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/_bootstrap?prevExist=false" \
        -XPUT -d value=${LISTEN_ADDRESS} -d ttl=${TTL} > /dev/null
    if [ $? -eq 0 ] ;
    then
        echo "Acquired bootstrap lock. Setting up node ..."
        SEED_COUNT=$(curl -Ls ${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/seeds | jq '.node.nodes | length')
        if [ $SEED_COUNT -lt $NEEDED_SEEDS ] ;
        then
            echo "Registering node as seed ..."
            curl -Lsf "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/seeds" \
                -XPOST -d value=${BROADCAST_ADDRESS:-$LISTEN_ADDRESS} > /dev/null
        fi

        # Register the cluster with OpsCenter if there's already at least 1 seed node
        if [ -n $OPSCENTER -a $SEED_COUNT -gt 0 ] ;
        then
            curl -Lsf "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/opscenter_ip?prevExist=false" \
                -XPUT -d value=${OPSCENTER} > /dev/null
            if [ $? -eq 0 ] ;
            then
                # First seed node is fine, it should allow opscenter to discover the rest
                SEED=$(curl -sL ${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/seeds | \
                    jq -r '.node.nodes[0].value')
                echo "Registering cluster with OpsCenter $OPSCENTER using seed $SEED ..."
                PAYLOAD="{\"cassandra\":{\"seed_hosts\":\"$SEED\"},\"cassandra_metrics\":{},\"jmx\":{\"port\":\"7199\"}}"
                curl -ksL http://${OPSCENTER}:8888/cluster-configs -X POST -d $PAYLOAD > /dev/null
            fi
        fi

        break
    else
        echo "Failed to acquire boostrap lock. Waiting for 5 seconds ..."
        sleep 5
    fi
done

echo "Finished bootstrapping node."
# Add route 53record seed1.${CLUSTER_NAME}.domain.tld ?

if [ -n "$OPSCENTER" ] ;
then
    echo "Configuring OpsCenter agent ..."
    echo "stomp_interface: $OPSCENTER" >> /var/lib/datastax-agent/conf/address.yaml
    echo "hosts: [\"$LISTEN_ADDRESS\"]" >> /var/lib/datastax-agent/conf/address.yaml
    echo "cassandra_conf: /opt/cassandra/conf/cassandra.yaml" >> /var/lib/datastax-agent/conf/address.yaml
    echo "Starting OpsCenter agent in the background ..."
    service datastax-agent start > /dev/null
fi

echo "Generating configuration from template ..."
python -c "import os; print os.path.expandvars(open('/opt/cassandra/conf/cassandra_template.yaml').read())" > /opt/cassandra/conf/cassandra.yaml
#python -c "import pystache, os; print(pystache.render(open('/opt/cassandra/conf/cassandra_template.yaml').read(), dict(os.environ)))" > /opt/cassandra/conf/cassandra.yaml


echo "Starting Cassandra ..."
/opt/cassandra/bin/cassandra -f \
    -Dcassandra.logdir=/var/cassandra/log \
    -Dcassandra.cluster_name=${CLUSTER_NAME} \
    -Dcassandra.listen_address=${LISTEN_ADDRESS} \
    -Dcassandra.broadcast_rpc_address=${LISTEN_ADDRESS}
