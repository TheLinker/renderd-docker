FROM postgres:10 as buildstage

RUN apt update && \
	apt -y install \
		apache2-dev \
		autoconf \
		build-essential \
		curl \
		gdal-bin \
		git \
		libboost-all-dev \
		libcairo2-dev \
		libcairomm-1.0-dev \
		libfreetype6-dev \
		libgdal-dev \
		libharfbuzz-dev \
		libicu-dev \
		libjpeg-dev \
		libltdl-dev \
		libpng-dev \
		libpq-dev \
		libproj-dev \
		libsqlite3-dev \
		libtiff5-dev \
		libwebp-dev \
		libxml2-dev \
		pktools \
		pktools-dev \
		postgresql-10-pgrouting \
		postgresql-10-pgrouting-scripts \
		postgresql-10-postgis-2.4 \
		postgresql-10-postgis-scripts \
		postgresql-contrib \
		postgresql-server-dev-10 \
		python-cairo-dev \
		python-dev \
		python-gdal \
		python-nose \
		ttf-dejavu \
		ttf-dejavu-core \
		ttf-dejavu-extra \
		ttf-unifont

ENV MAPNIK_VERSION v3.0.20
RUN	git clone --depth 1 --branch $MAPNIK_VERSION http://github.com/mapnik/mapnik
RUN cd /mapnik && \
    git submodule update --init
RUN NPROCS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1) && \
	cd /mapnik && \
	./configure && \
    JOBS=$NPROCS make && \
    make install

RUN curl -sL https://deb.nodesource.com/setup_8.x | bash - && \
	apt update && \
	apt install -y nodejs && \
	npm --unsafe-perm -g install millstone carto mapnik

RUN git clone --depth 1 https://github.com/openstreetmap/mod_tile/
RUN cd mod_tile && \
	./autogen.sh && \
	./configure && \
	make && \
	make install && \
	make install-mod_tile && \
	ldconfig && \
    cp debian/tileserver_site.conf /usr/local/etc && \
    cp debian/tile.load /usr/local/etc && \
    cp /usr/lib/apache2/modules/mod_tile.so /usr/local/lib/mod_tile.so

RUN mkdir -p /usr/local/share/ && \
    cd /usr/local/share && \
    git clone --depth 1 http://github.com/mapbox/osm-bright.git && \
    git clone --depth 1 https://github.com/gravitystorm/openstreetmap-carto.git

## grab gosu for easy step-down from root
ENV GOSU_VERSION 1.10
RUN set -x \
	&& apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/* \
	&& wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture)" \
	&& wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture).asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& gpg --keyserver ipv4.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
	&& gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
	&& rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc \
	&& chmod +x /usr/local/bin/gosu \
	&& gosu nobody true

FROM postgres:10 as runstage
COPY --from=buildstage /usr/local/ /usr/local/

RUN apt update && \
	apt -y install \
		apache2 \
		curl \
		fonts-dejavu-core \
		fonts-hanazono \
		fonts-noto-cjk \
		fonts-noto-hinted \
		fonts-noto-unhinted \
		netcat-traditional \
		libboost-regex1.62.0 \
	    osm2pgsql \
		ttf-dejavu \
		ttf-dejavu-core \
		ttf-dejavu-extra \
		ttf-unifont && \
	apt clean && \
	rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN curl -sL https://deb.nodesource.com/setup_8.x | bash - && \
	apt update && \
	apt install -y nodejs && \
	npm --unsafe-perm -g install carto mapnik && \
	apt clean && \
	rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mv /usr/local/lib/mod_tile.so /usr/lib/apache2/modules/mod_tile.so && \
	mv /usr/local/etc/tile.load /etc/apache2/mods-available && \
	cd /etc/apache2/mods-enabled && \
	ln -sf ../mods-available/tile.load && \
	mv /usr/local/etc/tileserver_site.conf /etc/apache2/sites-available && \
	cd /etc/apache2/sites-enabled && \
	rm * && \
	ln -s ../sites-available/tileserver_site.conf && \
	useradd -ms /bin/bash osm && \
	mkfifo -m 600 /var/log/logpipe && \
	chown osm /var/log/logpipe && \
	ln -sf /var/log/logpipe /var/log/apache2/access.log && \
	ln -sf /var/log/logpipe /var/log/apache2/error.log

RUN echo /usr/local/lib > /etc/ld.so.conf.d/local.conf && \
	ldconfig

COPY renderd.sh /usr/local/bin/renderd.sh
COPY apache.sh /usr/local/bin/apache.sh
COPY initdb.sh /usr/local/bin/initdb.sh
COPY config.sh /usr/local/etc/config.sh
COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
COPY wait_for_server.sh /usr/local/bin/wait_for_server.sh

VOLUME /data

EXPOSE 80
EXPOSE 7653

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]