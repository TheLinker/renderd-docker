#!/bin/bash


. /data/usr/local/etc/config.sh
export DATADIR POSTGRES_USER POSTGRES_DB POSTGRES_HOST POSTGRES_PASSWORD NPROCS OSM_PBF OSM_PBF_URL OSM_PBF_BASENAME \
	OSM_OSRM OSM2PGSQL_CACHE

cd /data && \
ln -sf usr/local/etc/config.sh && \
cd /

exec "$@"

exit 10
