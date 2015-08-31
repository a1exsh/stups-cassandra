FROM zalando/openjdk:8u45-b14-3

MAINTAINER Zalando <team-mop@zalando.de>

# Storage Port, JMX, Thrift, CQL Native, OpsCenter Agent
# Left out: SSL
EXPOSE 7000 7199 9042 9160 61621

ENV DEBIAN_FRONTEND=noninteractive
RUN echo "deb http://debian.datastax.com/community stable main" | tee -a /etc/apt/sources.list.d/datastax.community.list
RUN curl -sL https://debian.datastax.com/debian/repo_key | apt-key add -
RUN apt-get -y update && apt-get -y -o Dpkg::Options::='--force-confold' dist-upgrade
RUN apt-get -y install curl libjna-java python wget jq datastax-agent sysstat

ENV CASSIE_VERSION=2.1.8
ADD http://ftp.halifax.rwth-aachen.de/apache/cassandra/${CASSIE_VERSION}/apache-cassandra-${CASSIE_VERSION}-bin.tar.gz /tmp/
# COPY apache-cassandra-${CASSIE_VERSION}-bin.tar.gz /tmp/

RUN tar -xzf /tmp/apache-cassandra-${CASSIE_VERSION}-bin.tar.gz -C /opt && ln -s /opt/apache-cassandra-${CASSIE_VERSION} /opt/cassandra
RUN rm -f /tmp/apache-cassandra-${CASSIE_VERSION}-bin.tar.gz

RUN mkdir -p /var/cassandra/data

COPY cassandra_template.yaml /opt/cassandra/conf/
RUN rm -f /opt/cassandra/conf/cassandra.yaml && chmod 0777 /opt/cassandra/conf/
RUN ln -s /opt/cassandra/bin/nodetool /usr/bin && ln -s /opt/cassandra/bin/cqlsh /usr/bin

ADD https://bintray.com/artifact/download/lmineiro/maven/cassandra-etcd-seed-provider-1.0.jar /opt/cassandra/lib/
# ADD cassandra-etcd-seed-provider-1.0.jar /opt/cassandra/lib/

COPY stups-cassandra.sh /opt/cassandra/bin/
COPY supervisor.sh /opt/cassandra/bin/

CMD /opt/cassandra/bin/supervisor.sh
