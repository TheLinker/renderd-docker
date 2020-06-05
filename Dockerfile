FROM ubuntu:focal as buildstage

ENV BUMP 2020060101

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
        apache2-dev \
        build-essential \
        ca-certificates \
        git \
        libmapnik-dev \
        libmemcached-dev \
        librados-dev

RUN git clone --depth 1 --single-branch https://github.com/openstreetmap/mod_tile/
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

RUN mkdir -p /usr/local/share && \
    cd /usr/local/share && \
    git clone --depth 1 --single-branch https://github.com/mapbox/osm-bright.git && \
    git clone --depth 1 --single-branch https://github.com/gravitystorm/openstreetmap-carto.git



# --------------------------------------------------------------------------------------------- #

FROM ubuntu:focal as runstage

COPY --from=buildstage /usr/local/ /usr/local/

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apache2 \
        curl \
        fonts-dejavu-core \
        fonts-hanazono \
        fonts-noto-cjk \
        fonts-noto-hinted \
        fonts-noto-unhinted \
        gdal-bin \
        gosu \
        libgdal-grass \
        libmapnik3.0 \
        libmemcached11 \
        librados2 \
        mapnik-utils \
        netcat \
        osm2pgsql \
        osmium-tool \
        osmosis \
        postgresql-client-12 \
        pyosmium \
        python3 \
        python3-pip \
        python3-psycopg2 \
        python3-requests \
        python3-yaml \
        ttf-dejavu \
        ttf-dejavu-core \
        ttf-dejavu-extra \
        ttf-unifont \
        lua5.2

RUN mv /usr/local/lib/mod_tile.so /usr/lib/apache2/modules/mod_tile.so && \
    mv /usr/local/etc/tile.load /etc/apache2/mods-available && \
    mv /usr/local/etc/tileserver_site.conf /etc/apache2/sites-available && \
    a2dissite 000-default && \
    a2ensite tileserver_site && \
    a2enmod tile && \
    useradd -ms /bin/bash osm && \
    ldconfig

RUN mkdir /docker-entrypoint-initdb.d

RUN curl -sL https://deb.nodesource.com/setup_12.x | bash - && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN npm --unsafe-perm --global --production install carto mapnik

COPY renderd-docker-entrypoint.sh /usr/local/bin/
COPY osm-config.sh /usr/local/etc/
EXPOSE 80
EXPOSE 7653
VOLUME /data
ENTRYPOINT ["renderd-docker-entrypoint.sh"]
#CMD ["apache"]
