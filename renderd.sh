#!/bin/sh

. /data/config.sh

until [ -f /data/renderd-initdb.ready ]; do
    sleep 1
done

if [ ! -d /data/usr/local/etc ]; then
	mkdir -p /data/usr/local
	mv /usr/local/etc /data/usr/local
    sed -i -e 's#plugins_dir=.*#plugins_dir=/usr/local/lib/mapnik/input#' \
            -e "s#num_threads=.*#num_threads=$NPROCS#" \
            -e 's#tile_dir=.*#tile_dir=/data/var/lib/mod_tile#' \
            -e 's#TILEDIR=.*#tile_dir=/data/var/lib/mod_tile#' \
            -e 's#XML=.*#XML=/usr/local/share/openstreetmap-carto/osm.xml#' \
            -e 's#HOST=.*#HOST=localhost#' \
            -e 's#;MINZOOM=.*#MINZOOM=0#' \
            -e 's#;MAXZOOM=.*#MAXZOOM=20#' \
            -e 's#;socketname=.*#ipport=7653#' \
            -e 's#stats_file=.*#stats_file=/data/var/run/renderd/renderd.stats#' \
            -e 's#^;.*##' /data/usr/local/etc/renderd.conf
fi

if [ ! -d /data/var/run/renderd ]; then
	mkdir -p /data/var/run/renderd
	chown osm: /data/var/run/renderd
fi

cd /usr/local && \
	rm -rf etc && \
	ln -s /data/usr/local/etc

cd /etc && \
	rm -f renderd.conf && \
	ln -fs /data/usr/local/etc/renderd.conf

if [ ! -d /data/shapefiles ]; then
	gosu osm mkdir /data/shapefiles
	cd /usr/local/share/openstreetmap-carto
	./scripts/get-shapefiles.py
	mv data /data/shapefiles
	chown -R osm: /data/shapefiles
fi

cd /usr/local/share/openstreetmap-carto && \
	rm -rf data && \
	ln -sf /data/shapefiles/data

if [ ! -f /data/osm.xml ]; then
    cd /usr/local/share/openstreetmap-carto
    cat project.mml | awk '/dbname/ && !modif { printf("\
    host: \"'"$POSTGRES_HOST"'\"\n\
    port: '"$POSTGRES_PORT"'\n\
    user: \"'"$POSTGRES_USER"'\"\n\
    password: \"'"$POSTGRES_PASSWORD"'\"\n\
"); modif=1 } {print}' > project-modified.mml
	sed -i -e "s/dbname:.*/dbname: \"$POSTGRES_DB\"/" \
		project-modified.mml
	mv project-modified.mml project.mml
    gosu osm cp project.mml /data
fi


cd /usr/local/share/openstreetmap-carto && \
	rm -f osm.xml && \
	ln -s /data/osm.xml
cd /usr/local/share/openstreetmap-carto && \
	rm -f project.mml && \
	ln -s /data/project.mml
cd /usr/local/share/openstreetmap-carto && \
	carto project.mml > osm.xml

if [ ! -d /data/var/lib/mod_tile ]; then
	mkdir -p /data/var/lib/mod_tile
	chown osm: /data/var/lib/mod_tile
fi

cd /var/lib && \
	rm -rf mod_tile && \
	ln -s /data/var/lib/mod_tile

if [ ! -d /run/lock ]; then
	rm -f /run/lock
	mkdir /run/lock
	chmod 1777 /run/lock
fi

mkdir -p /run/renderd/
chown -R osm: /run/renderd

cd /
exec gosu osm renderd -f "$@"
