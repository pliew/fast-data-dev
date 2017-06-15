#!/usr/bin/env bash

ZK_PORT="${ZK_PORT:-2181}"
BROKER_PORT="${BROKER_PORT:-9092}"
BROKER_SSL_PORT="${BROKER_SSL_PORT:-9093}"
REGISTRY_PORT="${REGISTRY_PORT:-8081}"
REST_PORT="${REST_PORT:-8082}"
CONNECT_PORT="${CONNECT_PORT:-8083}"
WEB_PORT="${WEB_PORT:-3030}"
#KAFKA_MANAGER_PORT="3031"
RUN_AS_ROOT="${RUN_AS_ROOT:false}"
ZK_JMX_PORT="9585"
BROKER_JMX_PORT="9581"
REGISTRY_JMX_PORT="9582"
REST_JMX_PORT="9583"
CONNECT_JMX_PORT="9584"
DISABLE_JMX="${DISABLE_JMX:false}"
ENABLE_SSL="${ENABLE_SSL:false}"
SSL_EXTRA_HOSTS="${SSL_EXTRA_HOSTS:-}"
DEBUG="${DEBUG:-false}"
TOPIC_DELETE="${TOPIC_DELETE:-true}"

PORTS="$ZK_PORT $BROKER_PORT $REGISTRY_PORT $REST_PORT $CONNECT_PORT $WEB_PORT $KAFKA_MANAGER_PORT"

# Set webserver basicauth username and password
USER="${USER:-kafka}"
if [[ ! -z "$PASSWORD" ]]; then
    echo -e "\e[92mEnabling login credentials '\e[96m${USER}\e[34m\e[92m' '\e[96m${PASSWORD}'\e[34m\e[92m.\e[34m"
    echo "basicauth / \"${USER}\" \"${PASSWORD}\"" >> /usr/share/landoop/Caddyfile
fi

# Adjust custom ports

## Some basic replacements
sed -e 's/2181/'"$ZK_PORT"'/' -e 's/8081/'"$REGISTRY_PORT"'/' -e 's/9092/'"$BROKER_PORT"'/' -i \
    /opt/confluent/etc/kafka/zookeeper.properties \
    /opt/confluent/etc/kafka/server.properties \
    /opt/confluent/etc/kafka/connect-distributed.properties \
    /opt/confluent/etc/schema-registry/schema-registry.properties \
    /opt/confluent/etc/schema-registry/connect-avro-distributed.properties

## Broker specific
cat <<EOF >>/opt/confluent/etc/kafka/server.properties

listeners=PLAINTEXT://:$BROKER_PORT
confluent.support.metrics.enable=false
EOF

## Disabled because the basic replacements catch it
# cat <<EOF >>/opt/confluent/etc/schema-registry/schema-registry.properties

# listeners=http://0.0.0.0:$REGISTRY_PORT
# EOF

## REST Proxy specific
cat <<EOF >>/opt/confluent/etc/kafka-rest/kafka-rest.properties

listeners=http://0.0.0.0:$REST_PORT
schema.registry.url=http://localhost:$REGISTRY_PORT
zookeeper.connect=localhost:$ZK_PORT
EOF

## Schema Registry specific
cat <<EOF >>/opt/confluent/etc/kafka/connect-distributed.properties

rest.port=$CONNECT_PORT
EOF

cat <<EOF >>/opt/confluent/etc/schema-registry/connect-avro-distributed.properties

rest.port=$CONNECT_PORT
EOF

## Other infra specific (caddy, web ui, tests, logs)
sed -e 's/3030/'"$WEB_PORT"'/' -e 's/2181/'"$ZK_PORT"'/' -e 's/9092/'"$BROKER_PORT"'/' \
    -e 's/8081/'"$REGISTRY_PORT"'/' -e 's/8082/'"$REST_PORT"'/' -e 's/8083/'"$CONNECT_PORT"'/' \
    -i /usr/share/landoop/Caddyfile \
       /var/www/env.js \
       /usr/share/landoop/kafka-tests.yml \
       /usr/local/bin/logs-to-kafka.sh

# Allow for topic deletion by default, unless TOPIC_DELETE is set
if echo $TOPIC_DELETE | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    cat <<EOF >>/opt/confluent/etc/kafka/server.properties
delete.topic.enable=true
EOF
fi

# Remove ElasticSearch if needed
PREFER_HBASE="${PREFER_HBASE:-false}"
if echo $PREFER_HBASE | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    rm -rf /extra-connect-jars/* /opt/confluent-*/share/java/kafka-connect-elastic*
    echo -e "\e[92mFixing HBase connector: Removing ElasticSearch and Twitter connector.\e[39m"
fi

# Disable Connectors
OLD_IFS="$IFS"
IFS=","
for connector in $DISABLE; do
    echo "Disabling connector: kafka-connect-${connector}"
    rm -rf "/opt/confluent/share/java/kafka-connect-${connector}"
    [[ "elastic" == $connector ]] && rm -rf /extra-connect-jars/*
done
IFS="$OLD_IFS"

# Set ADV_HOST if needed
if [[ ! -z "${ADV_HOST}" ]]; then
    echo -e "\e[92mSetting advertised host to \e[96m${ADV_HOST}\e[34m\e[92m.\e[34m"
    echo -e "\nadvertised.listeners=PLAINTEXT://${ADV_HOST}:$BROKER_PORT" \
         >> /opt/confluent/etc/kafka/server.properties
    echo -e "\nrest.advertised.host.name=${ADV_HOST}" \
         >> /opt/confluent/etc/schema-registry/connect-avro-distributed.properties
    echo -e "\nrest.advertised.host.name=${ADV_HOST}" \
         >> /opt/confluent/etc/kafka/connect-distributed.properties
    sed -e 's#localhost#'"${ADV_HOST}"'#g' -i /usr/share/landoop/kafka-tests.yml /var/www/env.js /etc/supervisord.conf
fi

# Configure JMX if needed or disable it.
if ! echo "$DISABLE_JMX" | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    PORTS="$PORTS $BROKER_JMX_PORT $REGISTRY_JMX_PORT $REST_JMX_PORT $CONNECT_JMX_PORT $ZK_JMX_PORT"
    sed -r -e 's/^;(environment=JMX_PORT)/\1/' \
        -e 's/^environment=KAFKA_HEAP_OPTS/environment=JMX_PORT='"$CONNECT_JMX_PORT"',KAFKA_HEAP_OPTS/' \
        -i /etc/supervisord.conf
else
    sed -r -e 's/,KAFKA_JMX_OPTS="[^"]*"//' \
        -e 's/,SCHEMA_REGISTRY_JMX_OPTS="[^"]*"//' \
        -e 's/,KAFKAREST_JMX_OPTS="[^"]*"//' \
        -i /etc/supervisord.conf
    sed -e 's/"jmx"\s*:[^,]*/"jmx"  : ""/' \
        -i /var/www/env.js
fi

# Enable root-mode if needed
if egrep -sq "true|TRUE|y|Y|yes|YES|1" <<<"$RUN_AS_ROOT" ; then
    sed -e 's/user=nobody/;user=nobody/' -i /etc/supervisord.conf
    echo -e "\e[92mRunning Kafka as root.\e[34m"
fi

# SSL setup
if echo $ENABLE_SSL | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    PORTS="$PORTS $BROKER_SSL_PORT"
    echo -e "\e[92mTLS enabled. Creating CA and key-cert pairs.\e[34m"
    {
        mkdir /tmp/certs
        pushd /tmp/certs
        # Create Landoop Fast Data Dev CA
        quickcert -ca -out lfddca. -CN "Landoop's Fast Data Dev Self Signed Certificate Authority"
        SSL_HOSTS="localhost,127.0.0.1,192.168.99.100"
        [[ ! -z "$ADV_HOST" ]] && SSL_HOSTS="$SSL_HOSTS,$ADV_HOST"
        [[ ! -z "$SSL_EXTRA_HOSTS" ]] && SSL_HOSTS="$SSL_HOSTS,$SSL_EXTRA_HOSTS"

        # Create Key-Certificate pairs for Kafka and user
        for cert in kafka client; do
            quickcert -cacert lfddca.crt.pem -cakey lfddca.key.pem -out $cert. -CN "$cert" -hosts "$SSL_HOSTS" -duration 3650

            openssl pkcs12 -export \
                    -in $cert.crt.pem \
                    -inkey $cert.key.pem \
                    -out $cert.p12 \
                    -name $cert \
                    -passout pass:fastdata

            keytool -importkeystore \
                    -noprompt -v \
                    -srckeystore $cert.p12 \
                    -srcstoretype PKCS12 \
                    -srcstorepass fastdata \
                    -alias $cert \
                    -deststorepass fastdata \
                    -destkeypass fastdata \
                    -destkeystore $cert.jks
        done

        keytool -importcert \
                -noprompt \
                -keystore truststore.jks \
                -alias LandoopFastDataDevCA \
                -file lfddca.crt.pem \
                -storepass fastdata

        cat <<EOF >>/opt/confluent/etc/kafka/server.properties
ssl.client.auth=required
ssl.key.password=fastdata
ssl.keystore.location=$PWD/kafka.jks
ssl.keystore.password=fastdata
ssl.truststore.location=$PWD/truststore.jks
ssl.truststore.password=fastdata
ssl.protocol=TLS
ssl.enabled.protocols=TLSv1.2,TLSv1.1,TLSv1
ssl.keystore.type=JKS
ssl.truststore.type=JKS
EOF
        sed -r -e 's|^(listeners=.*)|\1,SSL://:'"${BROKER_SSL_PORT}"'|' \
            -i /opt/confluent/etc/kafka/server.properties
        [[ ! -z "${ADV_HOST}" ]] \
            && sed -r -e 's|^(advertised.listeners=.*)|\1,'"SSL://${ADV_HOST}:${BROKER_SSL_PORT}"'|' \
                   -i /opt/confluent/etc/kafka/server.properties

        mkdir /var/www/certs/
        cp client.jks truststore.jks /var/www/certs/

        popd
    } >/var/log/ssl-setup.log 2>&1
    sed -r -e 's|9093|'"${BROKER_SSL_PORT}"'|' \
        -i /var/www/env.js
    sed -e 's/ssl_browse/1/' -i /var/www/env.js
else
    sed -r -e 's|9093||' -i /var/www/env.js
fi

# Set web-only mode if needed
if echo $WEB_ONLY | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    PORTS="$WEB_PORT"
    echo -e "\e[92mWeb only mode. Kafka services will be disabled.\e[39m"
    cp /usr/share/landoop/supervisord-web-only.conf /etc/supervisord.conf
    cp /var/www/env-webonly.js /var/www/env.js
fi

# Set supervisord to output all logs to stdout
if echo $DEBUG | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    sed -e 's/loglevel=info/loglevel=debug/' -i /etc/supervisord.conf
fi

# Set supervisord to use the json config file if JSON is set to 1
if echo $JSON | egrep -sq "true|TRUE|y|Y|yes|YES|1"; then
    sed -e 's/schema-registry\/connect-avro-distributed.properties/kafka\/connect-distributed.properties/' -i /etc/supervisord.conf
fi

# Check for port availability
for port in $PORTS; do
    if ! /usr/local/bin/checkport -port $port; then
        echo "Could not successfully bind to port $port. Maybe some other service"
        echo "in your system is using it? Please free the port and try again."
        echo "Exiting."
        exit 1
    fi
done

# Check for Container's Memory Limit
MLMB="4096"
if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    MLB="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    MLMB="$(expr $MLB / 1024 / 1024)"
    MLREC=4096
    if [[ "$MLMB" -lt $MLREC ]]; then
        echo -e "\e[91mMemory limit for container is \e[93m${MLMB} MiB\e[91m, which is less than the lowest"
        echo -e "recommended of \e[93m${MLREC} MiB\e[91m. You will probably experience instability issues.\e[39m"
    fi
fi

# Check for Available RAM
RAKB="$(cat /proc/meminfo | grep MemA | sed -r -e 's/.* ([0-9]+) kB/\1/')"
if [[ -z "$RAKB" ]]; then
        echo -e "\e[91mCould not detect available RAM, probably due to very old Linux Kernel."
        echo -e "\e[91mPlease make sure you have the recommended minimum of \e[93m4096 MiB\e[91m RAM available for fast-data-dev.\e[39m"
else
    RAMB="$(expr $RAKB / 1024)"
    RAREC=5120
    if [[ "$RAMB" -lt $RAREC ]]; then
        echo -e "\e[91mOperating system RAM available is \e[93m${RAMB} MiB\e[91m, which is less than the lowest"
        echo -e "recommended of \e[93m${RAREC} MiB\e[91m. Your system performance may be seriously impacted.\e[39m"
    fi
fi

PRINT_HOST="${ADV_HOST:-localhost}"
[[ -f /build.info ]] && source /build.info
echo -e "\e[92mStarting services.\e[39m"
echo -e "\e[92mThis is landoop’s fast-data-dev. Kafka $KAFKA_VERSION, Confluent OSS $CP_VERSION.\e[39m"
echo -e "\e[34mYou may visit \e[96mhttp://${PRINT_HOST}:${WEB_PORT}\e[34m in about a minute.\e[39m"

# Set connect heap size if needed
CONNECT_HEAP="${CONNECT_HEAP:-1G}"
sed -e 's|{{CONNECT_HEAP}}|'"${CONNECT_HEAP}"'|' -i /etc/supervisord.conf

exec /usr/bin/supervisord -c /etc/supervisord.conf
