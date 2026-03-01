#!/usr/bin/env bash
set -euo pipefail

KUBEADM_FLAGS="${PODNODE_KUBEADM_FLAGS_PATH:-/var/lib/kubelet/kubeadm-flags.env}"
CPU_DESIRED_RAW="${PODNODE_CPU:-}"
MEM_DESIRED_RAW="${PODNODE_MEMORY:-}"
PODS_DESIRED_RAW="${PODNODE_PODS:-}"

if [[ -z "${CPU_DESIRED_RAW}" || -z "${MEM_DESIRED_RAW}" ]]; then
  exit 0
fi

# Wait for kubelet bootstrap to write kubeadm flags.
for _ in {1..300}; do
  if [[ -f "${KUBEADM_FLAGS}" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "${KUBEADM_FLAGS}" ]]; then
  exit 0
fi

HOST_CPU_CORES="${PODNODE_HOST_CPU_CORES:-$(nproc)}"
HOST_MEM_KI="${PODNODE_HOST_MEM_KI:-$(awk '/MemTotal:/ {print $2}' /proc/meminfo)}"

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
(( RESERVE_CPU_M < 0 )) && RESERVE_CPU_M=0

RESERVE_MEM_KI="$(( HOST_MEM_KI - DESIRED_MEM_KI ))"
(( RESERVE_MEM_KI < 0 )) && RESERVE_MEM_KI=0

F1="--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki"
F2="--system-reserved=cpu=0m,memory=0Ki"
F3="--enforce-node-allocatable=pods,kube-reserved,system-reserved"
F4="--kube-reserved-cgroup=/kubelet.slice"
F5="--system-reserved-cgroup=/system.slice"
F6=""
if [[ -n "${PODS_DESIRED_RAW}" && "${PODS_DESIRED_RAW}" =~ ^[0-9]+$ && "${PODS_DESIRED_RAW}" -gt 0 ]]; then
  F6="--max-pods=${PODS_DESIRED_RAW}"
fi

LINE="$(cat "${KUBEADM_FLAGS}")"
ARGS="$(printf "%s" "${LINE}" | sed -n 's/^KUBELET_KUBEADM_ARGS="\([^"]*\)".*$/\1/p')"
[[ -z "${ARGS}" ]] && exit 0

# Replace previous settings so re-runs are deterministic.
NEW_ARGS="${ARGS}"
NEW_ARGS="$(printf "%s" "${NEW_ARGS}" | sed -E 's@(^| )--kube-reserved=[^ ]+@@g; s@(^| )--system-reserved=[^ ]+@@g; s@(^| )--enforce-node-allocatable=[^ ]+@@g; s@(^| )--kube-reserved-cgroup=[^ ]+@@g; s@(^| )--system-reserved-cgroup=[^ ]+@@g; s@(^| )--max-pods=[^ ]+@@g; s@  +@ @g; s@^ @@; s@ $@@')"
NEW_ARGS="${NEW_ARGS} ${F1} ${F2} ${F3} ${F4} ${F5}"
if [[ -n "${F6}" ]]; then
  NEW_ARGS="${NEW_ARGS} ${F6}"
fi
NEW_ARGS="$(printf "%s" "${NEW_ARGS}" | sed -E 's@  +@ @g; s@^ @@; s@ $@@')"

if [[ "${NEW_ARGS}" != "${ARGS}" ]]; then
  printf 'KUBELET_KUBEADM_ARGS="%s"\n' "${NEW_ARGS}" > "${KUBEADM_FLAGS}"
  systemctl daemon-reload
  systemctl restart kubelet || true
fi

exit 0
