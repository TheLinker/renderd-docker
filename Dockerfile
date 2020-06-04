FROM osgeo/gdal:ubuntu-full-latest as buildstage

ENV BUMP 2020060101

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get -y --no-install-recommends install \
	    autoconf2.13  \
        apache2-dev \
        automake \
        autotools-dev \
        bison \
        build-essential \
        ca-certificates \
        ccache \
        clang \
        cmake \
        curl \
        dblatex \
        dctrl-tools \
        debhelper \
        dh-autoreconf \
        dirmngr \
        docbook \
        docbook-xsl \
        dpkg-dev \
        equivs \
        flex \
        fonts-dejavu \
        git \
        gnupg \
        gosu \
        imagemagick \
        libboost-filesystem1.67-dev \
        libboost-program-options1.67-dev \
        libboost-python1.67-dev \
        libboost-regex1.67-dev \
        libboost-system1.67-dev \
        libboost-thread1.67-dev \
        libboost1.67-dev \
        libbz2-dev \
        libcairo2-dev \
        libcairomm-1.0-1v5 \
        libcairomm-1.0-dev \
        libcunit1-dev \
        libcurl4-gnutls-dev \
        libexpat1-dev \
        libfreetype-dev \
        libgeos-dev \
        libgtk2.0-dev \
        libharfbuzz-dev \
        libicu-dev \
        libjpeg-turbo8-dev \
        libjson-c-dev  \
        liblua5.3-dev \
        libmemcached-dev \
        libnss-wrapper \
        libpixman-1-dev \
        libpng-dev \
        libproj-dev \
        libprotobuf-c-dev \
        libsigc++-2.0-0v5 \
        libsigc++-2.0-dev \
        libsqlite3-dev \
        libtiff-dev \
        libtool \
        libwebp-dev \
        libxml2-dev  \
        locales \
        lsb-release \
        make \
        pkg-config \
        po-debconf \
        protobuf-c-compiler \
        python3-cairo \
        python3-cairo-dev \
        python3-dev \
        python3-nose \
        python3-pip \
        rdfind \
        software-properties-common \
        ttf-dejavu \
        ttf-dejavu-core \
        ttf-dejavu-extra \
        ttf-unifont \
        unzip \
        wget \
        xsltproc \
        xz-utils \
        zlib1g-dev

# explicitly set user/group IDs
RUN set -eux; \
	groupadd -r postgres --gid=999; \
# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
# also create the postgres user's home directory with appropriate permissions
# see https://github.com/docker-library/postgres/issues/274
	mkdir -p /var/lib/postgresql; \
	chown -R postgres:postgres /var/lib/postgresql

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

RUN mkdir /docker-entrypoint-initdb.d

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
    echo "deb-src http://apt.postgresql.org/pub/repos/apt/ focal-pgdg main $PG_MAJOR" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update ; \
    tempDir="$(mktemp -d)"; \
    cd "$tempDir"; \
    apt-get build-dep -y \
        postgresql-common pgdg-keyring \
        "postgresql-$PG_MAJOR" \
    ; \
    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" \
        apt-get source --compile \
            postgresql-common pgdg-keyring \
            "postgresql-$PG_MAJOR"; \
    dpkg-scanpackages . > Packages; \
    echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list; \
    apt-get -o Acquire::GzipIndexes=false  update; \
	apt-get install -y --no-install-recommends postgresql-common; \
	sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
	apt-get install -y --no-install-recommends \
		"postgresql-$PG_MAJOR" \
		"postgresql-server-dev-$PG_MAJOR" \
		libecpg-dev \
		libpq-dev

#ENV MAPNIK_VERSION v3.0.22
ENV MAPNIK_VERSION master
#RUN rm -rf /var/lib/apt/lists/partial/* && \
#    apt-get -y --no-install-recommends install \
#        libboost-.*1.67-dev
RUN	git clone --depth 10 --branch $MAPNIK_VERSION --single-branch https://github.com/mapnik/mapnik
RUN cd /mapnik && \
    git submodule update --init
#RUN cd /mapnik && \
#    ./configure CUSTOM_CXXFLAGS="-D_GLIBCXX_USE_CXX11_ABI=0" CXX=clang++ CC=clang && \
#    make && \
#    make install && \
#    ldconfig
#
#RUN cd /tmp && \
#    equivs-control custom-equivs && \
#    sed -i 's/^Package:.*/Package: custom-equivs\nProvides: gdal-bin (=4), libgdal26 (=4), libgdal-dev (=4), gdal-data (=4), mapnik-utils (=4), libmapnik3.0 (=4), libmapnik-dev (=4), postgresql-all, postgresql-server-dev-all/' custom-equivs && \
#    equivs-build custom-equivs && \
#    dpkg -i custom-equivs_1.0_all.deb
#
#COPY ./pg_buildext /usr/local/bin/
#RUN cd /tmp/tmp* && \
#    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"  apt-get source --compile postgis && \
#    dpkg-scanpackages . > Packages && \
#    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::GzipIndexes=false update && \
#    apt-get install -y postgis && \
#    rm -f /etc/apt/sources.list.d/temp.list
#
#RUN git clone --depth 1 --single-branch https://github.com/openstreetmap/mod_tile/
#COPY mapnik_compile_fix.patch /mod_tile/
#RUN cd mod_tile && \
#    patch -p1 < mapnik_compile_fix.patch && \
#    ./autogen.sh && \
#    ./configure && \
#    make && \
#    make install && \
#    make install-mod_tile && \
#    ldconfig && \
#    cp debian/tileserver_site.conf /usr/local/etc && \
#    cp debian/tile.load /usr/local/etc && \
#    cp /usr/lib/apache2/modules/mod_tile.so /usr/local/lib/mod_tile.so
#
#RUN mkdir -p /usr/local/share/debs && \
#    cd /usr/local/share && \
#    git clone --depth 1 --single-branch http://github.com/mapbox/osm-bright.git && \
#    git clone --depth 1 --single-branch https://github.com/gravitystorm/openstreetmap-carto.git
#
#RUN git clone --depth 1 --single-branch https://github.com/openstreetmap/osm2pgsql.git
#RUN cd osm2pgsql && \
#    mkdir build && \
#    cd build && \
#    cmake .. && \
#    make && \
#    make install
#
#FROM osgeo/gdal:ubuntu-full-latest as runstage
#COPY --from=buildstage /usr/local/ /usr/local/
#COPY --from=buildstage /tmp/tmp*/*.deb /usr/local/share/debs/
#
#RUN set -eux; \
#	groupadd -r postgres --gid=999; \
## https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
#	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
## also create the postgres user's home directory with appropriate permissions
## see https://github.com/docker-library/postgres/issues/274
#	mkdir -p /var/lib/postgresql; \
#	chown -R postgres:postgres /var/lib/postgresql
#ENV LANG en_US.utf8
#
#RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
#    apt-get install -y --no-install-recommends \
#        dpkg-dev \
#	    locales && \
#	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 && \
#    cd /usr/local/share/debs && \
#    dpkg-scanpackages . > Packages && \
#    echo "deb [ trusted=yes ] file://$(pwd) ./" > /etc/apt/sources.list.d/temp.list && \
#    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::GzipIndexes=false update && \
#    apt-get install -y --no-install-recommends \
#        postgresql-common && \
#    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf && \
#    apt-get install -y --no-install-recommends \
#        apache2 \
#        curl \
#        fonts-dejavu-core \
#        fonts-hanazono \
#        fonts-noto-cjk \
#        fonts-noto-hinted \
#        fonts-noto-unhinted \
#        gosu \
#        libboost-filesystem1.67.0 \
#        libboost-python1.67.0 \
#        libboost-regex1.67.0 \
#        libboost-system1.67.0 \
#        liblua5.3-0 \
#        libmemcached11 \
#        libnss-wrapper \
#        netcat-traditional \
#        postgis \
#        postgresql-12 \
#        postgresql-12-postgis-3 \
#        postgresql-client \
#        postgresql-contrib \
#        python3-pip \
#        ttf-dejavu \
#        ttf-dejavu-core \
#        ttf-dejavu-extra \
#        ttf-unifont \
#        xz-utils && \
#    apt-get purge -y dpkg-dev && \
#    apt-get autoremove -y --purge && \
#    apt-get clean && \
#    rm -f /etc/apt/sources.list.d/temp.list && \
#    rm -rf /var/lib/apt/lists/*
#    # find /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' +
#
#RUN mkdir /docker-entrypoint-initdb.d
#
#ENV PG_MAJOR 12
#RUN set -eux; \
#	dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample"; \
#	cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \
#	ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/"; \
#	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/postgresql.conf.sample; \
#	grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample
#
#RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql
#
#ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin
#ENV PGDATA /var/lib/postgresql/data
## this 777 will be replaced by 700 at runtime (allows semi-arbitrary "--user" values)
#RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA"
#VOLUME /var/lib/postgresql/data
#
#RUN curl -sL https://deb.nodesource.com/setup_12.x | bash - && \
#    DEBIAN_FRONTEND=noninteractive apt-get update && \
#    apt-get install -y --no-install-recommends nodejs && \
#    apt-get clean && \
#    rm -rf /var/lib/apt/lists/*
#
#RUN curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
#     echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
#     DEBIAN_FRONTEND=noninteractive apt-get update && \
#        apt-get install -y --no-install-recommends yarn && \
#    apt-get clean && \
#    rm -rf /var/lib/apt/lists/*
#
#RUN npm --unsafe-perm --global --production install carto mapnik
#
#RUN mv /usr/local/lib/mod_tile.so /usr/lib/apache2/modules/mod_tile.so && \
#    mv /usr/local/etc/tile.load /etc/apache2/mods-available && \
#    cd /etc/apache2/mods-enabled && \
#    ln -sf ../mods-available/tile.load && \
#    mv /usr/local/etc/tileserver_site.conf /etc/apache2/sites-available && \
#    cd /etc/apache2/sites-enabled && \
#    rm * && \
#    ln -s ../sites-available/tileserver_site.conf && \
#    useradd -ms /bin/bash osm && \
#    ldconfig
#
#RUN pip3 install osmium
#
#COPY docker-entrypoint.sh /usr/local/bin/
#COPY renderd-docker-entrypoint.sh /usr/local/bin/
#COPY osm-config.sh /usr/local/etc/
#RUN ln -s usr/local/bin/docker-entrypoint.sh / # backwards compat
#
#EXPOSE 5432
#EXPOSE 80
#EXPOSE 7653
#
#VOLUME /data
#
#ENTRYPOINT ["renderd-docker-entrypoint.sh"]
#CMD ["postgres"]
