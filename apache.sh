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

cd /usr/local && \
	rm -rf etc && \
	ln -s /data/usr/local/etc
cd /etc && \
	rm -f renderd.conf && \
	ln -fs /usr/local/etc/renderd.conf

cd /var/lib && \
	rm -rf mod_tile && \
	ln -s /data/var/lib/mod_tile

cd /

. /etc/apache2/envvars  && \
	mkdir -p "$APACHE_RUN_DIR" && \
    rm -f $APACHE_PID_FILE && \
    rm -f "$APACHE_LOG_DIR"/error.log "$APACHE_LOG_DIR"/access.log && \
    ln -sf /dev/stdout "$APACHE_LOG_DIR"/error.log && \
    ln -sf /dev/stdout "$APACHE_LOG_DIR"/access.log && \
    exec /usr/sbin/apache2 -DFOREGROUND
