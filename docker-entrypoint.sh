#!/bin/bash

echo "starting $@"

if [ -f /usr/local/etc/osm-config.sh ]; then
    . /usr/local/etc/osm-config.sh
fi

chown osm: /data

cd /var/lib && \
    rm -rf mod_tile && \
    ln -s /data/var/lib/mod_tile

if [ ! -d /run/lock ]; then
    rm -f /run/lock
    mkdir /run/lock
    chmod 1777 /run/lock
fi

cd /usr/local/share/openstreetmap-carto && \
    rm -rf data && \
    ln -sf /data/shapefiles/data

cd /

function wait_for_server () {
    server_host=$1
    server_port=$2
    sleep_seconds=5

    while true; do
        echo -n "Checking $server_host $server_port status... "

        nc -z "$server_host" "$server_port"

        if [ "$?" -eq 0 ]; then
            echo "$server_host is running and ready to process requests."
            break
        fi

        echo "$server_host is warming up. Trying again in $sleep_seconds seconds..."
        sleep $sleep_seconds
    done
}

if [ "$1" == "renderd-initdb" ]; then
    shift
    rm -f /data/renderd-initdb.ready
    touch /data/renderd-initdb.init

    if [ "$REDOWNLOAD" -o ! -f /data/"$OSM_PBF" -a "$OSM_PBF_URL" ]; then
        echo "downloading $OSM_PBF_URL"
        gosu osm curl -L -z /data/"$OSM_PBF" -o /data/"$OSM_PBF" "$OSM_PBF_URL"
        gosu osm curl -L -o /data/"$OSM_PBF".md5 "$OSM_PBF_URL".md5
        cd /data && \
            gosu osm md5sum -c "$OSM_PBF".md5 || { rm -f /data/"$OSM_PBF"; exit 1; }
        REINITDB=1
    fi

    if [ ! -d /data/shapefiles/data ]; then
        echo "downloading shapefiles"
        gosu osm mkdir /data/shapefiles
        cd /usr/local/share/openstreetmap-carto
        rm -rf data
        ./scripts/get-shapefiles.py
        mv data /data/shapefiles
        chown -R osm: /data/shapefiles
        ln -sf /data/shapefiles/data
    fi

    until echo select 1 | gosu postgres psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" template1 &> /dev/null ; do
        echo "Waiting for postgres"
        sleep 5
    done

    if [ "$REINITDB" ] || ! $(echo select 1 | gosu postgres psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" &> /dev/null) ; then
        dropdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB"
        createdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" && (
            cat << EOF | psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB"
                CREATE EXTENSION IF NOT EXISTS postgis;
                CREATE EXTENSION IF NOT EXISTS postgis_topology;
                CREATE EXTENSION IF NOT EXISTS hstore;
EOF
            )
        REPROCESS=1
    fi

    if [ "$REPROCESS" ]; then
        echo "importing $OSM_PBF"
        osm2pgsql -G -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
            --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
            --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
            --hstore --hstore-add-index \
            --number-processes $NPROCS \
            /data/"$OSM_PBF"
        psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" -f /usr/local/share/openstreetmap-carto/indexes.sql
        echo "CREATE INDEX planet_osm_line_index_1 ON planet_osm_line USING GIST (way);" | \
            psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
        gosu osm mv -f /data/osm.xml /data/osm.xml.old
        echo "VACUUM FULL FREEZE VERBOSE ANALYZE;" | psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
    fi

    rm -f /data/renderd-initdb.init

    gosu osm touch /data/renderd-initdb.ready
    exit 0
fi

if [ "$1" == "renderd-apache2" ]; then
    shift
    wait_for_server renderd 7653
    cp /data/osm.xml /usr/local/share/openstreetmap-carto/

    . /etc/apache2/envvars  && \
        mkdir -p "$APACHE_RUN_DIR" && \
        rm -f $APACHE_PID_FILE && \
        rm -f "$APACHE_LOG_DIR"/error.log "$APACHE_LOG_DIR"/access.log && \
        ln -sf /dev/stdout "$APACHE_LOG_DIR"/error.log && \
        ln -sf /dev/stdout "$APACHE_LOG_DIR"/access.log
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
    exec /usr/sbin/apache2 -DFOREGROUND
fi


if [ "$1" == "renderd" ]; then
    shift
    sleep 5
    until [ -f /data/renderd-initdb.ready ]; do
        echo "Waiting for renderd-initdb"
        sleep 5
    done

    if [ ! -d /data/var/run/renderd ]; then
        mkdir -p /data/var/run/renderd
        chown osm: /data/var/run/renderd
    fi

    if [ "$REDOWNLOAD" -o "$REEXTRACT" -o "$REINITDB" -o ! -f /data/osm.xml ]; then
        cd /usr/local/share/openstreetmap-carto
        # it's a yaml file, indentation is important
        cat project.mml | awk '/dbname/ && !modif { printf("\
    host: \"'"$POSTGRES_HOST"'\"\n\
    port: '"$POSTGRES_PORT"'\n\
    user: \"'"$POSTGRES_USER"'\"\n\
    password: \"'"$POSTGRES_PASSWORD"'\"\n\
"); modif=1 } {print}' > project-modified.mml
        sed -i -e "s/dbname:.*/dbname: \"$POSTGRES_DB\"/" \
            project-modified.mml
        mv project-modified.mml project.mml
        carto project.mml > /data/osm.xml
    fi

    cp /data/osm.xml /usr/local/share/openstreetmap-carto

    if [ ! -d /data/var/lib/mod_tile ]; then
        mkdir -p /data/var/lib/mod_tile
        chown osm: /data/var/lib/mod_tile
    fi

    mkdir -p /run/renderd/
    chown -R osm: /run/renderd

    cd /

    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi

    exec gosu osm renderd -f
fi

exec "$@"

exit 10
