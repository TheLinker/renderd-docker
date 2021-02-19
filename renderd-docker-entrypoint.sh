#!/bin/sh

set -e

. /usr/local/etc/osm-config.sh
log starting

if [ "$1" = "postgres" ]; then
  exec docker-entrypoint.sh "$@"
fi

id osm >/dev/null 2>&1 &&
  chown osm: /data

# for backwards compatibility because the location of mapnik/input has changed to
#  /usr/lib/mapnik/3.0/input from /usr/local/lib/mapnik/input
if [ ! -d /usr/local/lib/mapnik ]; then
  mkdir -p /usr/local/lib
  cd /usr/local/lib
  ln -s /usr/lib/mapnik/3.0 mapnik
fi

cd /var/lib &&
  rm -rf mod_tile &&
  ln -s /data/var/lib/mod_tile

if [ ! -d /run/lock ]; then
  rm -f /run/lock
  mkdir /run/lock
  chmod 1777 /run/lock
fi

cd /

wait_for_server() {
  server_host=$1
  server_port=$2
  : ${WFS_SLEEP:=30}
  while true; do
    log -n "Checking $server_host $server_port status... "

    if nc -zu "$server_host" 1 | grep -q "Unknown host"; then
      log "host $server_host not found, returning 1"
      return 1
    fi

    nc -z "$server_host" "$server_port" || {
      echo "$server_host is warming up. Trying again in $WFS_SLEEP seconds..."
      sleep "$WFS_SLEEP"
      continue
    }

    echo "$server_host is running and ready to process requests"
    return 0
  done
}

shapefiles_dir() {
  case "$1" in
  create)
    log "creating shapefiles dir"
    (
      cd /usr/local/share/openstreetmap-carto &&
        gosu osm mkdir -p /data/shapefiles/data
      if [ -d data ] && [ ! -h data ]; then
        gosu osm cp -a data/* /data/shapefiles/data
      fi
      rm -rf data &&
        gosu osm mkdir -p /data/shapefiles/data &&
        ln -sf /data/shapefiles/data
    ) || return 1
    ;;
  delete)
    log "deleting shapefiles dir"
    rm -rf /data/shapefiles/data
    gosu osm mkdir -p /data/shapefiles/data
    return 0
    ;;
  *)
    echo "$0 [create|delete]"
    return 2
    ;;
  esac
  return 0
}

check_lockfile() {
  if [ -z "$1" ]; then
    log "check_lockfile <lockfile> [log prefix]"
    return 0
  fi
  LOCKFILE="$1"

  if [ -f "$LOCKFILE" ]; then
    log "$2 $LOCKFILE found, previous run didn't finish successfully, rerunning"
    eval $(grep "restartcount=[0-9]\+" "$LOCKFILE")
    restartcount=$(($restartcount + 1))
    if [ "$restartcount" -gt 2 ]; then
      if [ "$restartcount" -gt 24 ]; then
        restartcount=24
      fi
      log "$2 has failed $restartcount times before, sleeping for $(($restartcount * 3600)) seconds"
      sleep $(($restartcount * 3600))
    fi
    echo "restartcount=$restartcount" >"$LOCKFILE"
    return 1
  fi

  echo "restartcount=0" >"$LOCKFILE"
  eval $(grep "restartcount=[0-9]\+" "$LOCKFILE")
  return 0
}

download() {
  URL="$1"
  FILE="$2"
  if [ -z "$URL" ]; then
    log "$SUBCOMMAND download <url> [filename]"
    return 1
  fi
  # this isn't super robust, if the url is http://blah.com FILE will be blah.com
  # if the url is http://blah.com/file/data.bin FILE will be data.bin (which is what we want)
  # it might be better to use curl -O but that adds complications with the curl arguments
  if [ -z "$FILE" ]; then
    FILE=$(echo "$URL" | sed 's#.*/##')
    if [ -z "$FILE" ]; then
      FILE="index.html"
    fi
  fi
  cd "$DATA_DIR"
  gosu osm flock "$FILE".lock curl --remote-time --location --retry 3 --time-cond "$FILE" \
    --silent --show-error --output "$FILE" "$URL" || {
    log "$SUBCOMMAND error downloading $URL"
    rm -f "$FILE".lock
    return 2
  }
  rm -f "$FILE".lock
}

if [ "$1" = "renderd-reinitdb" ]; then
  log "$1 called, reinitializing database"
  REINITDB=1 exec $0 renderd-initdb
fi

if [ "$1" = "renderd-reprocess" ]; then
  log "$1 called, reprocessing"
  REPROCESS=1 exec $0 renderd-initdb
fi

if [ "$1" = "renderd-redownload" ]; then
  log "$1 called, redownloading files"
  REDOWNLOAD=1 exec $0 renderd-initdb
fi

if [ "$1" = "renderd-updatedb" ]; then
  log "$1 called"

  if [ -z "$OSM_PBF_UPDATE_URL" ]; then
    log "$1 OSM_PBF_UPDATE_URL not set, exit 1"
    exit 1
  fi

  shapefiles_dir create || exit 19

  # give renderd-initdb time to start and create lock file
  sleep 5

  until [ ! -f /data/renderd-initdb.lock ]; do
    log "$1 waiting for renderd-initdb to finish"
    sleep "$WFS_SLEEP"
  done

  while true; do
    # If it fails 3 times sleep for 3 hours to rate limit how often we try to download from the upstream server
    check_lockfile /data/renderd-updatedb.lock "$1" || true

    if [ ! -f /data/osmosis/configuration.txt ]; then
      log "$1 initialising replication interval"
      gosu osm osmosis --read-replication-interval-init workingDirectory=/data/osmosis/ || {
        log "$1 error initialising replication interval, exit 18"
        exit 18
      }
      gosu osm sed -i -e "s#baseUrl=.*#baseUrl=$OSM_PBF_UPDATE_URL#" \
        -e "s/maxInterval.*/maxInterval = 43200/" /data/osmosis/configuration.txt
    fi

    if [ ! -f /data/osmosis/state.txt ]; then
      log "$1 /data/osmosis/state.txt missing, redownloading, updates might be missing, you probably should redownload and reinitialise"
      download "$OSM_PBF_UPDATE_URL"/state.txt /data/osmosis/state.txt
    fi

    cd /data/osmosis
    if [ -f "changes.osc.gz" ]; then
      eval $(grep "sequenceNumber=[0-9]\+" state.txt)
      log "$1 old change file found which would indicate a previous error and exit, reprocessing $sequenceNumber"
      log "$1 updating database"
      gosu osm osm2pgsql --append -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
        --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
        --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
        --hstore --hstore-add-index changes.osc.gz || {
        log "$1 osm2pgsql error applying changes to database, exit 22"
        sleep 10
        exit 22
      }
      mv -f changes.osc.gz changes-processed.osc.gz
    fi

    if [ -f "changes-processed.osc.gz" ]; then
      log "$1 updating /data/$OSM_PBF"
      gosu osm osmosis --read-xml-change file=changes-processed.osc.gz --read-pbf file=/data/"$OSM_PBF" --apply-change \
        --write-pbf file="$OSM_PBF" &&
        mv "$OSM_PBF" /data/"$OSM_PBF" || {
        log "$1 error applying changes, exit 23"
        sleep 10
        exit 23
      }
      rm -f changes-processed.osc.gz
    fi

    eval $(grep "sequenceNumber=[0-9]\+" /data/osmosis/state.txt)
    oldsequenceNumber="$sequenceNumber"
    count=0
    cd /data/osmosis
    log "checking for new change file and downloading"
    gosu osm osmosis --read-replication-interval workingDirectory=/data/osmosis --simplify-change \
      --write-xml-change changes.osc.gz || {
      log "$1 error downloading changes from $OSM_PBF_UPDATE_URL, exit 5"
      exit 5
    }
    eval $(grep "sequenceNumber=[0-9]\+" state.txt)

    until [ "$oldsequenceNumber" = "$sequenceNumber" -o "$count" -gt 30 ]; do
      log "processing sequence number $sequenceNumber"
      count=$(($count + 1))
      log "updating database"
      gosu osm osm2pgsql --append -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
        --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
        --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
        --hstore --hstore-add-index changes.osc.gz || {
        log "$1 osm2pgsql error applying changes to database, exit 3"
        exit 3
      }
      mv -f changes.osc.gz changes-processed.osc.gz
      log "$1 updating /data/$OSM_PBF"
      gosu osm osmosis --read-xml-change file=changes-processed.osc.gz --read-pbf file=/data/"$OSM_PBF" --apply-change \
        --write-pbf file="$OSM_PBF" &&
        mv "$OSM_PBF" /data/"$OSM_PBF" || {
        log "$1 error applying changes, exit 17"
        exit 17
      }
      rm -f changes-processed.osc.gz
      oldsequenceNumber="$sequenceNumber"
      gosu osm osmosis --read-replication-interval workingDirectory=/data/osmosis --simplify-change \
        --write-xml-change changes.osc.gz || {
        log "$1 error downloading changes from $OSM_PBF_UPDATE_URL, exit 6"
        exit 6
      }
      eval $(grep "sequenceNumber=[0-9]\+" state.txt)
      if [ "$oldsequenceNumber" = "$sequenceNumber" ]; then
        rm -f changes.osc.gz
        break
      fi
      sleep 10
    done

    rm -f /data/renderd-updatedb.lock /data/osmosis/changes.osc.gz
    : ${RENDERD_UPDATE_SLEEP:=86400}
    log "$1 finished, sleeping for $RENDERD_UPDATE_SLEEP seconds"
    sleep "$RENDERD_UPDATE_SLEEP"

  done
  exit 0
fi

if [ "$1" = "renderd-initdb" ]; then
  log "$1 called"

  check_lockfile /data/renderd-initdb.lock "$1" || REDOWNLOAD=1

  if [ "$REDOWNLOAD" ] || [ -f /data/REDOWNLOAD ] || [ ! -f /data/"$OSM_PBF" ] && [ "$OSM_PBF_URL" ]; then
    log "$1 downloading $OSM_PBF_URL"
    rm -f /data/REDOWNLOAD
    gosu osm mkdir -p /data/osmosis
    download "$OSM_PBF_UPDATE_URL"/state.txt /data/osmosis/state.txt || {
      touch /data/renderd-REDOWNLOAD
      log "$1 error downloading ${OSM_PBF_UPDATE_URL}/state.txt, exit 7"
      exit 7
    }
    download "$OSM_PBF_URL" || {
      touch /data/renderd-REDOWNLOAD
      log "$1 error downloading $OSM_PBF_URL, exit 8"
      exit 8
    }
    download "$OSM_PBF_URL".md5 || {
      touch /data/renderd-REDOWNLOAD
      log "$1 error downloading ${OSM_PBF_URL}.md5, exit 9"
      exit 9
    }
    (cd /data &&
      gosu osm md5sum -c "$OSM_PBF".md5) || {
      rm -f /data/"$OSM_PBF".md5 /data/"$OSM_PBF"
      log "$1 md5sum mismatch on /data/$OSM_PBF, exit 4"
      exit 4
    }
    REINITDB=1
    REDOWNLOAD=1 # for shapefiles below
  fi

  shapefiles_dir create || exit 16

  until echo select 1 | gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" template1 >/dev/null 2>/dev/null; do
    log "$1 Waiting for postgres"
    sleep "$WFS_SLEEP"
  done

  if [ "$REINITDB" ] || [ -f /data/REINITDB ] || ! $(echo "SELECT 'tables already created' FROM pg_catalog.pg_tables where tablename = 'planet_osm_nodes'" |
    gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" | grep -q 'tables already created'); then
    log "$1 reiniting database"
    rm -f /data/REINITDB /data/REDOWNLOAD
    gosu osm createuser osm -s -h "$POSTGRES_HOST" -U "$POSTGRES_USER" || true
    gosu osm dropdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" || true
    gosu osm createdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" && (
      cat <<EOF | psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB"
                CREATE EXTENSION IF NOT EXISTS postgis;
                CREATE EXTENSION IF NOT EXISTS postgis_topology;
                CREATE EXTENSION IF NOT EXISTS hstore;
EOF
    ) || {
      touch /data/renderd-REINITDB
      log "$1 error creating database schema, exit 12"
      exit 12
    }
    REPROCESS=1
  fi

  if [ "$REPROCESS" ] || [ -f /data/REPROCESS ]; then
    log "$1 importing $OSM_PBF"
    rm -f /data/REINITDB /data/REDOWNLOAD /data/REPROCESS
    gosu osm osm2pgsql -G -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
      --style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
      --tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
      --hstore --hstore-add-index \
      --number-processes $NPROCS \
      /data/"$OSM_PBF" || {
      touch /data/renderd-REPROCESS
      log "$1 error importing $OSM_PBF, exit 13"
      exit 13
    }
    gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" -f /usr/local/share/openstreetmap-carto/indexes.sql
    echo "CREATE INDEX planet_osm_line_index_1 ON planet_osm_line USING GIST (way);" |
      gosu osm psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
    rm -f /data/osm.xml
    echo "VACUUM FULL FREEZE VERBOSE ANALYZE;" | gosu osm psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB"
  fi

  if [ "$REDOWNLOAD" ] || [ ! "$(ls /usr/local/share/openstreetmap-carto/data/)" ]; then
    log "$1 downloading shapefiles"
    (cd /usr/local/share/openstreetmap-carto &&
      gosu osm ./scripts/get-external-data.py -H "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -D /data/shapefiles/data) || {
      log "$1 error downloading shapefiles, exit 11"
      shapefiles_dir delete
      exit 11
    }
  fi

  rm -f /data/renderd-initdb.lock
  rm -f /data/REINITDB /data/REDOWNLOAD /data/REPROCESS
  exit 0
fi

if [ "$1" = "renderd-apache2" ]; then
  log "$1 called"
  shift

  wait_for_server renderd 7653
  cp /data/osm.xml /usr/local/share/openstreetmap-carto/
  shapefiles_dir create || exit 20

  . /etc/apache2/envvars &&
    mkdir -p "$APACHE_RUN_DIR" &&
    rm -f "$APACHE_PID_FILE" &&
    rm -f "$APACHE_LOG_DIR"/error.log "$APACHE_LOG_DIR"/access.log &&
    ln -sf /dev/stdout "$APACHE_LOG_DIR"/error.log &&
    ln -sf /dev/stdout "$APACHE_LOG_DIR"/access.log

  if [ "$#" -gt 0 ]; then
    exec "$@"
  fi
  exec /usr/sbin/apache2 -DFOREGROUND
fi

if [ "$1" = "renderd" ]; then
  log "$1 called"
  shift

  sleep 5
  until [ ! -f /data/renderd-initdb.lock ]; do
    log "$1 waiting for renderd-initdb to finish"
    sleep "$WFS_SLEEP"
  done

  if [ ! -d /data/var/run/renderd ]; then
    mkdir -p /data/var/run/renderd
    chown osm: /data/var/run/renderd
  fi

  shapefiles_dir create || exit 21

  if [ "$REDOWNLOAD" -o "$REEXTRACT" -o "$REINITDB" -o ! -f /data/osm.xml ]; then
    log "$1 generating stylesheet"
    (
      cd /usr/local/share/openstreetmap-carto
      # it's a yaml file, indentation is important
      cat project.mml | awk '/dbname/ && !modif { printf("\
    host: \"'"$POSTGRES_HOST"'\"\n\
    port: '"$POSTGRES_PORT"'\n\
    user: \"'"$POSTGRES_USER"'\"\n\
    password: \"'"$POSTGRES_PASSWORD"'\"\n\
"); modif=1 } {print}' >project-modified.mml
      sed -i -e "s/dbname:.*/dbname: \"$POSTGRES_DB\"/" \
        project-modified.mml
      gosu osm carto project-modified.mml >/data/osm.xml
    ) || {
      log "$1 error generating carto stylesheet, exit 15"
      exit 15
    }
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
