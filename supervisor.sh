#!/bin/sh
#
# This is a supervisor script that handles things we need to do before
# starting the cassandra process and continious monitoring after that.
#
TTL=${TTL:-30}
SLEEP_INTERVAL=${SLEEP_INTERVAL:-60}

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

EC2_META_URL=http://169.254.169.254/latest/meta-data

# TODO: use public-* if multi-region
export LISTEN_ADDRESS=$(curl -s ${EC2_META_URL}/local-ipv4)
NODE_HOSTNAME=$(curl -s ${EC2_META_URL}/local-hostname)
NODE_ZONE=$(curl -s ${EC2_META_URL}/placement/availability-zone)
echo "Node IP address is $LISTEN_ADDRESS ..."
echo "Node hostname is $NODE_HOSTNAME ..."
echo "Node availability zone is $NODE_ZONE ..."

curl -s "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/size?prevExist=false" \
    -XPUT -d value=${CLUSTER_SIZE} > /dev/null

SEEDS_URL="${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/seeds"
ETCD_OPSCENTER_URL="${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/opscenter"

# Add route 53record seed1.${CLUSTER_NAME}.domain.tld ?

# for the nodetool
export CASSANDRA_HOME=/opt/cassandra
export CASSANDRA_INCLUDE=${CASSANDRA_HOME}/bin/cassandra.in.sh

query_seeds() {
    curl -sL "${SEEDS_URL}" | jq -r '.node.nodes[].value' | \
        while read data; do \
            echo $data | jq -r '.host'; \
        done
}

register_in_opscenter() {
    STOMP_INTERFACE=$(echo $OPSCENTER | awk -F/ '{print $3}')
    echo "Configuring OpsCenter agent with stopm_interface $STOMP_INTERFACE ..."
    echo "stomp_interface: $STOMP_INTERFACE" | tee -a /var/lib/datastax-agent/conf/address.yaml

    echo "Starting OpsCenter agent in the background ..."
    service datastax-agent start

    SEEDS=$(echo $(query_seeds) | tr \  ,)
    echo "Registering cluster with OpsCenter using seeds $SEEDS ..."
    curl ${OPSCENTER}/cluster-configs -X POST \
         -d "{
               \"cassandra\": {
                 \"seed_hosts\": \"$SEEDS\"
               },
               \"cassandra_metrics\": {},
               \"jmx\": {
                 \"port\": \"7199\"
               }
             }" > /dev/null
}

bootstrap_lock() {
    echo "Trying to acquire bootstrap lock ..."
    curl -Lsf "${ETCD_URL}/v2/keys/cassandra/${CLUSTER_NAME}/_bootstrap?prevExist=false" \
         -XPUT -d value=${LISTEN_ADDRESS} -d ttl=${TTL} > /dev/null
}

register_as_seed() {
    echo "Registering this node as the seed for zone ${NODE_ZONE} ..."
    curl -Lsf "${SEEDS_URL}/${NODE_HOSTNAME}" \
         -XPUT -d value="{\"host\":\"${LISTEN_ADDRESS}\",\"availabilityZone\":\"${NODE_ZONE}\"}" > /dev/null
}

remove_stale_seed() {
    node=$1
    echo "Removing stale seed entry: $node ..."
    curl -Lsf "${SEEDS_URL}/${node}" -XDELETE > /dev/null
}

REPLACE_ADDRESS_PARAM=''

# for the very first node, we have to declare itself a seed before starting Cassandra up
while true; do
    if bootstrap_lock ;
    then
        echo "Acquired bootstrap lock."

        SEEDS=$(query_seeds)
        if [ -z "$SEEDS" ] ;
        then
            echo "No seed nodes yet, assuming fresh cluster start ..."
            register_as_seed
        else
            echo "There are already some seed nodes ..."

            for seed in $SEEDS; do
                echo "Querying a seed node ${seed} for the cluster status ..."
                if nodetool -h $seed status >/tmp/nodetool-remote-status ;
                then
                    DEAD_NODE_ADDRESS=$(grep '^D. ' </tmp/nodetool-remote-status | awk '{print $2; exit}')
                    if [ -n "$DEAD_NODE_ADDRESS" ] ;
                    then
                        echo "There was a dead node at ${DEAD_NODE_ADDRESS}, will try to replace it ..."
                        REPLACE_ADDRESS_PARAM=-Dcassandra.replace_address=${DEAD_NODE_ADDRESS}
                    fi
                    # we've reached one seed, no point to keep trying
                    break
                else
                    # This might be a seed from an earlier incarnation of this
                    # cluster *with the same version.*  We have to remove it,
                    # otherwise cassandra won't be able to start at all.
                    remove_stale_seed $seed

                    # And also remove earlier OpsCenter registration key if any.
                    curl -Lsf "${ETCD_OPSCENTER_URL}?recursive=true" -XDELETE > /dev/null
                fi
            done
        fi
        break
    else
        echo "Failed to acquire bootstrap lock. Waiting for 5 seconds ..."
        sleep 5
    fi
done

./stups-cassandra.sh ${REPLACE_ADDRESS_PARAM} &

# wake up every so often to check the node's status and the current seeds list
while true; do
    echo "Checking Boot status ..."
    BOOT_STATUS=$(nodetool netstats | grep '^Mode: ' | awk '{print $2}')

    echo "Boot status is $BOOT_STATUS ..."
    if [ "${BOOT_STATUS}" = NORMAL ] ;
    then
        # first check for any stale seed entries and remove them
        curl -sL "${ETCD_URL}/v2/keys/taupage" \
            | jq -r '.node.nodes[].key' | awk -F/ '{print $3}' | \
            sort >/tmp/stups-all-host-names

        curl -sL "${SEEDS_URL}" \
            | jq -r '.node.nodes[].key' | awk -F/ '{print $5}' | \
            sort >/tmp/stups-cassandra-seed-names

        echo "The list of all hosts as currently set by taupage: " \
             $(tr \\n \  </tmp/stups-all-host-names)
        echo "The list of seeds as currently known by etcd: " \
             $(tr \\n \  </tmp/stups-cassandra-seed-names)

        STALE_SEED_NAMES=$(diff --old-line-format= \
                                --new-line-format=%L \
                                --unchanged-group-format= \
                                /tmp/stups-all-host-names \
                                /tmp/stups-cassandra-seed-names)

        for node in $STALE_SEED_NAMES; do
            remove_stale_seed $node
        done

        # Now see if we don't have a seed in our availability zone (yet or anymore);
        # if that's the case, try to become one.
        while true; do
            echo "Checking seeds availability zones ..."

            curl -sL "${SEEDS_URL}" | jq -r '.node.nodes[].value' | \
                while read data; do \
                    echo $data | jq -r '.availabilityZone'; \
                done | \
                grep "^${NODE_ZONE}\$" >/dev/null
            if [ $? -ne 0 ] ;
            then
                echo "No seed node found in availability zone ${NODE_ZONE} ..."
                if bootstrap_lock ;
                then
                    register_as_seed
                    break
                else
                    echo "Failed to acquire bootstrap lock. Waiting for 5 seconds ..."
                    sleep 5
                fi
            else
                echo "There is already a seed in availability zone ${NODE_ZONE} ..."
                if [ -n "$OPSCENTER" ] ;
                then
                    # check if it's the first time
                    curl -Lsf "${ETCD_OPSCENTER_URL}?prevExist=false" \
                         -XPUT -d value=${OPSCENTER} > /dev/null
                    if [ $? -eq 0 ] ;
                    then
                        register_in_opscenter
                    fi
                fi
                break
            fi
        done
    fi

    echo "Sleeping ..."
    sleep ${SLEEP_INTERVAL}
done
