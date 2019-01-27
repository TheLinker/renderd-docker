FROM postgres:10 as buildstage

ENV BUMP 2019011101

RUN apt update && \
    apt -y install \
        apache2-dev \
        autoconf \
        build-essential \
        curl \
        gdal-bin \
        git \
        libboost-all-dev \
        libbz2-dev \
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
        postgresql-10-postgis \
        postgresql-10-postgis-scripts \
        postgresql-contrib \
        postgresql-server-dev-10 \
        python-cairo-dev \
        python-dev \
        python-gdal \
        python-nose \
        python-pip \
        python3-pip \
        ttf-dejavu \
        ttf-dejavu-core \
        ttf-dejavu-extra \
        ttf-unifont

RUN pip3 install osmium
RUN pip install osmium

ENV MAPNIK_VERSION v3.0.22
RUN	git clone --depth 1 --branch $MAPNIK_VERSION --single-branch http://github.com/mapnik/mapnik
RUN cd /mapnik && \
    git submodule update --init
RUN cd /mapnik && \
    ./configure && \
    make && \
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
        gosu \
        netcat-traditional \
        libboost-python1.62.0 \
        libboost-regex1.62.0 \
        osm2pgsql \
        osmosis \
        postgresql-10-pgrouting \
        postgresql-10-pgrouting-scripts \
        postgresql-10-postgis \
        postgresql-10-postgis-scripts \
        postgresql-contrib \
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
    ldconfig

COPY renderd-docker-entrypoint.sh /usr/local/bin/
COPY osm-config.sh /usr/local/etc/

VOLUME /data

EXPOSE 80
EXPOSE 7653

ENTRYPOINT ["renderd-docker-entrypoint.sh"]
