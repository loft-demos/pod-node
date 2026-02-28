#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/podnode-clamp-allocatable.sh >/var/log/podnode-allocatable-watcher.log 2>&1 &
exec /entrypoint.sh
