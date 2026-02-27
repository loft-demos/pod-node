#!/usr/bin/env bash
set -euo pipefail

CPU_DESIRED_RAW="${PODNODE_CPU:-}"
MEM_DESIRED_RAW="${PODNODE_MEMORY:-}"

# If not set, do nothing
if [[ -z "${CPU_DESIRED_RAW}" || -z "${MEM_DESIRED_RAW}" ]]; then
  exit 0
fi

# Wait for kubelet to be installed by Auto Nodes
for i in {1..120}; do
  if command -v kubelet >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Wait for systemd unit to exist
for i in {1..120}; do
  if systemctl list-unit-files | grep -q '^kubelet\.service'; then
    break
  fi
  sleep 1
done

# Host totals (what kubelet currently advertises)
HOST_CPU_CORES="$(nproc)"
HOST_MEM_KI="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"

cpu_to_millicores() {
  local v="$1"
  if [[ "$v" =~ m$ ]]; then
    echo "${v%m}"
    return
  fi
  awk -v c="$v" 'BEGIN { printf "%d", c*1000 }'
}

mem_to_ki() {
  local v="$1"
  if [[ "$v" =~ Ki$ ]]; then
    echo "${v%Ki}"
  elif [[ "$v" =~ Mi$ ]]; then
    awk -v x="${v%Mi}" 'BEGIN { printf "%d", x*1024 }'
  elif [[ "$v" =~ Gi$ ]]; then
    awk -v x="${v%Gi}" 'BEGIN { printf "%d", x*1024*1024 }'
  else
    echo "$v"
  fi
}

DESIRED_CPU_M="$(cpu_to_millicores "${CPU_DESIRED_RAW}")"
DESIRED_MEM_KI="$(mem_to_ki "${MEM_DESIRED_RAW}")"

HOST_CPU_M="$(awk -v c="${HOST_CPU_CORES}" 'BEGIN { printf "%d", c*1000 }')"
RESERVE_CPU_M="$(( HOST_CPU_M - DESIRED_CPU_M ))"
if (( RESERVE_CPU_M < 0 )); then RESERVE_CPU_M=0; fi

RESERVE_MEM_KI="$(( HOST_MEM_KI - DESIRED_MEM_KI ))"
if (( RESERVE_MEM_KI < 0 )); then RESERVE_MEM_KI=0; fi

mkdir -p /etc/systemd/system/kubelet.service.d

cat >/etc/systemd/system/kubelet.service.d/20-podnode-allocatable.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki --system-reserved=cpu=0m,memory=0Ki"
EOF

systemctl daemon-reload

# kubelet should exist by now; restart to apply args
systemctl restart kubelet || true
