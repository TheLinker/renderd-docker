#!/bin/bash

echo "starting $@"

if [ -f /usr/local/etc/osm-config.sh ]; then
    . /usr/local/etc/osm-config.sh
fi

if [ "$1" == "postgres" ]; then
    exec docker-entrypoint.sh "$@"
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

if [ "$1" == "renderd-reinitdb" ]; then
    echo "$1" called, reinitializing database
    REINITDB=1 exec $0 renderd-initdb
fi

if [ "$1" == "renderd-reprocess" ]; then
    echo "$1" called, reprocessing database
    REPROCESS=1 exec $0 renderd-initdb
fi

if [ "$1" == "renderd-redownload" ]; then
    echo "$1" called, redownloading "$OSM_PBF_URL"
    REDOWNLOAD=1 exec $0 renderd-initdb
fi

if [ "$1" == "renderd-updatedb" ]; then
    echo "$1" called

    if [ -z "$OSM_PBF_UPDATE_URL" ]; then
        echo "$1 OSM_PBF_UPDATE_URL not set, exiting"
        exit 1
    fi

    if [ -f /data/renderd-updatedb.lock ]; then
        echo "previous $1 still running or crashed, exiting without updating"
        exit 2
    fi

    sleep 5
    until [ ! -f /data/renderd-initdb.init -a -f /data/renderd-initdb.ready ]; do
        echo "$1 waiting for init to finish"
        sleep 30
    done

    gosu osm touch /data/renderd-updatedb.lock

    if [ ! -f /data/osmosis/configuration.txt ]; then
        gosu osm osmosis --read-replication-interval-init workingDirectory=/data/osmosis/
        gosu osm sed -i -e "s#baseUrl=.*#baseUrl=$OSM_PBF_UPDATE_URL#" \
                        -e "s/maxInterval.*/maxInterval = 43200/" /data/osmosis/configuration.txt
    fi

    if [ ! -f /data/osmosis/state.txt ]; then
        gosu osm curl "$OSM_PBF_UPDATE_URL"/state.txt -o /data/osmosis/state.txt
    fi
    eval `grep sequenceNumber= /data/osmosis/state.txt`
    oldsequenceNumber="$sequenceNumber"
    count=0
    cd /data/osmosis
    gosu osm osmosis --read-replication-interval workingDirectory=/data/osmosis --simplify-change \
        --write-xml-change changes.osc.gz || { echo "Error downloading changes from $OSM_PBF_UPDATE_URL, exit 5"; exit 5; }
    eval `grep sequenceNumber= state.txt`
    until [ "$oldsequenceNumber" == "$sequenceNumber" -o "$count" -gt 30 ]; do
        let count=count+1
        gosu osm osm2pgsql --append -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
            --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
            --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
            --hstore --hstore-add-index changes.osc.gz || { echo "osm2pgsql error applying changes to database, exit 3"; exit 3; }
        oldsequenceNumber="$sequenceNumber"
        gosu osm osmosis --read-replication-interval workingDirectory=/data/osmosis --simplify-change \
                            --write-xml-change changes.osc.gz || { echo "Error downloading changes from $OSM_PBF_UPDATE_URL, exit 6"; exit 6; }
        eval `grep sequenceNumber= state.txt`
        if [ "$oldsequenceNumber" == "$sequenceNumber" ]; then
            break
        fi
        gosu osm osmosis --read-xml-change file=changes.osc.gz --read-pbf file=/data/"$OSM_PBF" --apply-change \
                        --write-pbf file="$OSM_PBF" && \
            mv "$OSM_PBF" /data/"$OSM_PBF"
        sleep 10
    done

    rm -f /data/renderd-updatedb.lock
    exit 0
fi

shapefiles_dir () {
    case "$1" in
    create) echo "Creating shapefiles dir"
        ( cd /usr/local/share/openstreetmap-carto && \
            rm -rf data && \
            gosu osm mkdir -p /data/shapefiles/data && \
            ln -sf /data/shapefiles/data
        ) || return 1
    ;;
    delete) echo "Deleting shapefiles dir"
        rm -rf /data/shapefiles/data
        gosu osm mkdir -p /data/shapefiles/data
    ;;
    *) echo "$0 [create|delete]"
        return 2
    ;;
    esac
    return 0
}

if [ "$1" == "renderd-initdb" ]; then
    echo "$1" called
    shift

    if [ -f /data/renderd-initdb.init ]; then
        echo "Interrupted renderd-initdb detected, rerunning reinitdb"
        REDOWNLOAD=1
    fi

    rm -f /data/renderd-initdb.ready
    gosu osm touch /data/renderd-initdb.init

    if [ "$REDOWNLOAD" -o ! -f /data/"$OSM_PBF" -a "$OSM_PBF_URL" ]; then
        echo "downloading $OSM_PBF_URL"
        gosu osm mkdir -p /data/osmosis
        gosu osm curl "$OSM_PBF_UPDATE_URL"/state.txt -o /data/osmosis/state.txt || {
            echo "error downloading ${OSM_PBF_UPDATE_URL}/state.txt, exit 7"; exit 7; }
        gosu osm curl -L -z /data/"$OSM_PBF" -o /data/"$OSM_PBF" "$OSM_PBF_URL" || {
            echo "error downloading $OSM_PBF_URL, exit 8"; exit 8; }
        gosu osm curl -L -o /data/"$OSM_PBF".md5 "$OSM_PBF_URL".md5 || {
            echo "error downloading ${OSM_PBF_URL}.md5, exit 9"; exit 9; }
        ( cd /data && \
            gosu osm md5sum -c "$OSM_PBF".md5 ) || {
                rm -f "$OSM_PBF".md5 "$OSM_PBF"; echo "md5sum mismatch on /data/$OSM_PBF, exit 4"; exit 4
            }
        REINITDB=1
    fi

    shapefiles_dir create || exit 16

    if [ ! "$(ls /usr/local/share/openstreetmap-carto/data/)" -o "$REDOWNLOAD" ]; then
        echo "downloading shapefiles"
        ( cd /usr/local/share/openstreetmap-carto && \
            gosu osm ./scripts/get-shapefiles.py ) || {
                echo "error downloading shapefiles, exit 11"
                shapefiles_dir delete
                exit 11
            }
    fi

    until echo select 1 | gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" template1 &> /dev/null ; do
        echo "Waiting for postgres"
        sleep 5
    done

    if [ "$REINITDB" ] || ! $(echo select 1 | gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" &> /dev/null) ; then
        gosu osm dropdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB"
        gosu osm createdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" && (
            cat << EOF | psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB"
                CREATE EXTENSION IF NOT EXISTS postgis;
                CREATE EXTENSION IF NOT EXISTS postgis_topology;
                CREATE EXTENSION IF NOT EXISTS hstore;
EOF
            ) || { echo "error creating database schema, exit 12"; exit 12; }
        REPROCESS=1
    fi

    if [ "$REPROCESS" ]; then
        echo "importing $OSM_PBF"
        gosu osm osm2pgsql -G -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
            --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
            --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
            --hstore --hstore-add-index \
            --number-processes $NPROCS \
            /data/"$OSM_PBF" || { echo "error importing $OSM_PBF, exit 13"; exit 13; }
        gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" -f /usr/local/share/openstreetmap-carto/indexes.sql
        echo "CREATE INDEX planet_osm_line_index_1 ON planet_osm_line USING GIST (way);" | \
            gosu osm psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
        gosu osm mv -f /data/osm.xml /data/osm.xml.old
        echo "VACUUM FULL FREEZE VERBOSE ANALYZE;" | gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB"
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
        rm -f "$APACHE_PID_FILE" && \
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
        sleep 30
    done

    if [ ! -d /data/var/run/renderd ]; then
        mkdir -p /data/var/run/renderd
        chown osm: /data/var/run/renderd
    fi

    shapefiles_dir create

    if [ "$REDOWNLOAD" -o "$REEXTRACT" -o "$REINITDB" -o ! -f /data/osm.xml ]; then
        ( cd /usr/local/share/openstreetmap-carto
        # it's a yaml file, indentation is important
        cat project.mml | awk '/dbname/ && !modif { printf("\
    host: \"'"$POSTGRES_HOST"'\"\n\
    port: '"$POSTGRES_PORT"'\n\
    user: \"'"$POSTGRES_USER"'\"\n\
    password: \"'"$POSTGRES_PASSWORD"'\"\n\
"); modif=1 } {print}' > project-modified.mml
        sed -i -e "s/dbname:.*/dbname: \"$POSTGRES_DB\"/" \
            project-modified.mml
        carto project-modified.mml > /data/osm.xml ) || { echo "error generating carto stylesheet, exit 15"; exit 15; }
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
        exec renderd "$@"
    fi

    exec gosu osm renderd -f
fi

exec "$@"

exit 10
