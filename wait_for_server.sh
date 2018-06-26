#!/bin/sh

server_host=$1
server_port=$2
sleep_seconds=5

if [ -z "$1" -o -z "$2" ]; then
	echo "$0" host port
	exit 1
fi

while true; do
    echo -n "Checking $server_host $server_port status... "

    nc -z "$server_host" "$server_port"

    if [ "$?" -eq 0 ]; then
        echo "$server_host is running and ready to process requests."
        break
    fi

    echo "$server_host is warming up. Trying again in $sleep_seconds seconds..."
    sleep "$sleep_seconds"
done