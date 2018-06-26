#!/bin/sh


wait_for_server.sh renderd 7653


. /data/config.sh

if [ ! -d /data/etc/apache2 ]; then
	mkdir -p /data/etc
	cp -a /etc/apache2 /data/etc
	sed -i -e 's/ServerName.*/ServerName localhost/' \
	       -e 's/ServerAlias.*/ServerAlias */' \
		   -e 's#/var/lib/mod_tile#/data/var/lib/mod_tile#' \
		   -e 's#ModTileRenderdSocketName.*#ModTileRenderdSocketAddr renderd 7653#' \
		    /data/etc/apache2/sites-available/tileserver_site.conf
fi

rm -rf /etc/apache2
cd /etc && \
ln -s /data/etc/apache2

rm -rf /usr/local/etc
cd /usr/local && \
ln -s /data/usr/local/etc
rm -f /etc/renderd.conf
cd /etc && \
ln -fs /usr/local/etc/renderd.conf

rm -rf /var/lib/mod_tile
cd /var/lib && \
ln -s /data/var/lib/mod_tile

cd /

# https://github.com/docker/docker/issues/6880
cat <> /var/log/logpipe 1>&2 &

. /etc/apache2/envvars  && \
	mkdir -p $APACHE_RUN_DIR && \
    rm -f $APACHE_PID_FILE && \
    exec /usr/sbin/apache2 -DFOREGROUND
