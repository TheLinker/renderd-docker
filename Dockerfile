FROM ubuntu:focal as buildstage

ENV BUMP 20200830.1

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
        dirmngr \
        fonts-dejavu-core \
        fonts-hanazono \
        fonts-noto-cjk \
        fonts-noto-hinted \
        fonts-noto-unhinted \
        gdal-bin \
        gnupg \
        gosu \
        libgdal-grass \
        libmapnik3.0 \
        libmemcached11 \
        librados2 \
        mapnik-utils \
        netcat \
        osm2pgsql \
        osmosis \
        python3 \
        python3-pip \
        ttf-dejavu \
        ttf-dejavu-core \
        ttf-dejavu-extra \
        ttf-unifont \
        lua5.2 && \
    rm -rf /var/lib/apt/lists/*

# explicitly set user/group IDs
RUN set -eux; \
	groupadd -r postgres --gid=999; \
# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
# also create the postgres user's home directory with appropriate permissions
# see https://github.com/docker-library/postgres/issues/274
	mkdir -p /var/lib/postgresql; \
	chown -R postgres:postgres /var/lib/postgresql

RUN set -ex; \
# pub   4096R/ACCC4CF8 2011-10-13 [expires: 2019-07-02]
#       Key fingerprint = B97B 0AFC AA1A 47F0 44F2  44A0 7FCC 7D46 ACCC 4CF8
# uid                  PostgreSQL Debian Repository
	key='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8'; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	gpg --batch --export "$key" > /etc/apt/trusted.gpg.d/postgres.gpg; \
	command -v gpgconf > /dev/null && gpgconf --kill all; \
	rm -rf "$GNUPGHOME"; \
	apt-key list

ENV PG_MAJOR 12

RUN set -ex; \
	\
    echo "deb http://apt.postgresql.org/pub/repos/apt/ focal-pgdg main $PG_MAJOR" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postgresql-client-12; \
    rm -rf /var/lib/apt/lists/*

RUN set -ex; \
	\
    apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	    build-essential \
	    libpq-dev \
	    libpq5 \
	    python3-dev; \
	python3 -m pip install wheel setuptools; \
	python3 -m pip install osmium psycopg2 requests pyyaml; \
	apt-get purge -y \
	    build-essential \
	    libpq-dev \
	    python3-dev; \
    apt-get autoremove --purge -y; \
    rm -rf /var/lib/apt/lists/*

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
    rm -rf /var/lib/apt/lists/*

RUN npm --unsafe-perm --global --production install carto mapnik

COPY renderd-docker-entrypoint.sh /usr/local/bin/
COPY osm-config.sh /usr/local/etc/
EXPOSE 80
EXPOSE 7653
VOLUME /data
ENTRYPOINT ["renderd-docker-entrypoint.sh"]
#CMD ["apache"]
