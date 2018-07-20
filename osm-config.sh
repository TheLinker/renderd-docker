#!/bin/sh

# these will only be set if they aren't already set
: ${NPROCS:=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1)}
: ${POSTGRES_PASSWORD:=supersecret}
: ${POSTGRES_HOST:=postgres}
: ${POSTGRES_USER:=postgres}
: ${POSTGRES_DB:=gis}
: ${POSTGRES_PORT:=5432}
: ${OSM_PBF_URL:=http://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf}
: ${OSM_PBF:=$(basename "$OSM_PBF_URL")}
: ${OSM_PBF_BASENAME:=$(basename "$OSM_PBF" .osm.pbf)}
: ${OSM_OSRM:="$OSM_PBF_BASENAME".osrm}
: ${OSM2PGSQLCACHE:=1000}

export DATADIR POSTGRES_USER POSTGRES_DB POSTGRES_HOST POSTGRES_PASSWORD NPROCS OSM_PBF OSM_PBF_URL OSM_PBF_BASENAME \
	OSM_OSRM OSM2PGSQLCACHE


if [ ! -f ~/.pgpass ]; then
    touch ~/.pgpass
    chmod 600 ~/.pgpass
    echo "$POSTGRES_HOST:$POSTGRES_PORT:*:$POSTGRES_USER:$POSTGRES_PASSWORD" >> ~/.pgpass
fi

for U in osm osrm postgres; do
	if id "$U" &> /dev/null && [ ! -f /home/"$U"/.pgpass ]; then
		if [ ! -d /home/"$U" ]; then
			mkdir /home/"$U"
			chown "$U": /home/"$U"
		fi
	    touch /home/"$U"/.pgpass
	    chown "$U": /home/"$U"/.pgpass
	    chmod 600 /home/"$U"/.pgpass
	    echo "$POSTGRES_HOST:$POSTGRES_PORT:*:$POSTGRES_USER:$POSTGRES_PASSWORD" >> /home/"$U"/.pgpass
	fi
done
