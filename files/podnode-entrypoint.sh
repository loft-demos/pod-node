#!/usr/bin/env bash
set -euo pipefail

require_exec() {
  local p="$1"
  if [[ ! -x "${p}" ]]; then
    echo "pod-node startup error: required executable not found: ${p}" >&2
    exit 1
  fi
}

require_exec /entrypoint.sh
require_exec /usr/local/bin/podnode-clamp-allocatable.sh
require_exec /escape-cgroup.sh
require_exec /create-kubelet-cgroup.sh

/usr/local/bin/podnode-clamp-allocatable.sh >/var/log/podnode-allocatable-watcher.log 2>&1 &
exec /entrypoint.sh
