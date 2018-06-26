#!/bin/bash


if [ ! -f /data/config.sh ]; then
	mv /usr/local/etc/config.sh /data
fi

rm -f /usr/local/etc/config.sh

. /data/config.sh

exec "$@"

exit 10
