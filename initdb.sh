#!/bin/bash

rm -f /data/initdb.ready

. /data/config.sh

if [ "$REDOWNLOAD" -o ! -f /data/"$OSM_PBF" -a "$OSM_PBF_URL" ]; then
	curl -L -z /data/"$OSM_PBF" -o /data/"$OSM_PBF" "$OSM_PBF_URL"
	REINITDB=1
fi

if [ "$REINITDB" ]; then
	until psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" -w &>/dev/null; do
        echo "Waiting for postgres"
        sleep 5
	done
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
	osm2pgsql -G -U "$POSTGRES_USER" -d "$POSTGRES_DB" -H "$POSTGRES_HOST" --slim -C "$OSM2PGSQLCACHE" \
		--style /usr/local/share/openstreetmap-carto/openstreetmap-carto.style \
		--tag-transform-script /usr/local/share/openstreetmap-carto/openstreetmap-carto.lua \
		--hstore --hstore-add-index \
        --number-processes $NPROCS \
        /data/"$OSM_PBF"
    psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" -f /usr/local/share/openstreetmap-carto/indexes.sql

#  Filter: ((planet_osm_line.highway IS NOT NULL) AND ((planet_osm_line.tunnel IS NULL)
#  OR (planet_osm_line.tunnel <> ALL ('{yes,building_passage}'::text[]))) AND ((planet_osm_line.covered IS NULL)
#  OR (planet_osm_line.covered <> 'yes'::text)) AND (planet_osm_line.way && '010etry)
#  AND ((planet_osm_line.bridge IS NULL)
#  OR (planet_osm_line.bridge <> ALL ('{yes,boardwalk,cantilever,covered,low_water_crossing,movable,trestle,viaduct}'::text[]))))

	echo "CREATE INDEX planet_osm_line_index_1
  ON planet_osm_line USING GIST (way);" | psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB

	mv -f /data/osm.xml /data/osm.xml.old

	echo "VACUUM FULL FREEZE VERBOSE ANALYZE;" | psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB

fi

touch /data/initdb.ready
