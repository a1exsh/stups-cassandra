#!/bin/sh
# CLUSTER_NAME
# DATA_DIR
# COMMIT_LOG_DIR
# LISTEN_ADDRESS
     
export DATA_DIR=${DATA_DIR:-/var/cassandra/data}
export COMMIT_LOG_DIR=${COMMIT_LOG_DIR:-/var/cassandra/data/commit_logs}

echo "Generating configuration from template ..."
python -c "import os; print os.path.expandvars(open('${CASSANDRA_HOME}/conf/cassandra_template.yaml').read())" > ${CASSANDRA_HOME}/conf/cassandra.yaml
#python -c "import pystache, os; print(pystache.render(open('${CASSANDRA_HOME}/conf/cassandra_template.yaml').read(), dict(os.environ)))" > ${CASSANDRA_HOME}/conf/cassandra.yaml

echo "Starting Cassandra ..."
${CASSANDRA_HOME}/bin/cassandra -f \
    -Dcassandra.logdir=/var/cassandra/log \
    -Dcassandra.cluster_name=${CLUSTER_NAME} \
    -Dcassandra.listen_address=${LISTEN_ADDRESS} \
    -Dcassandra.broadcast_rpc_address=${LISTEN_ADDRESS} \
    $*
