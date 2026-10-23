#!/bin/sh
set -eu
mkdir -p /data
if [ "$(id -u)" = 0 ]; then
    chown zeus:zeus /data
    exec gosu zeus "$@"
fi
exec "$@"
