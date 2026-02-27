FROM ubuntu:noble

ARG TARGETARCH

RUN apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y \
      curl fuse binutils jq conntrack iptables strace \
      apt-transport-https iproute2 ca-certificates gpg \
      systemd systemd-sysv dbus cloud-init kmod && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /home

# Keep your existing entrypoint + any other files you already use
COPY files /

# -----------------------------------------------------------------------------
# Helper: write /etc/vcluster/vcluster-flags.env based on PODNODE_CPU/MEMORY
# -----------------------------------------------------------------------------
RUN cat << 'EOF' > /usr/local/bin/podnode-write-vcluster-flags.sh
#!/usr/bin/env bash
set -euo pipefail

CPU_DESIRED_RAW="${PODNODE_CPU:-}"
MEM_DESIRED_RAW="${PODNODE_MEMORY:-}"

if [[ -z "${CPU_DESIRED_RAW}" || -z "${MEM_DESIRED_RAW}" ]]; then
  exit 0
fi

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

mkdir -p /etc/vcluster

cat > /etc/vcluster/vcluster-flags.env <<EOF2
KUBELET_EXTRA_ARGS=--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki --system-reserved=cpu=0m,memory=0Ki --enforce-node-allocatable=pods,kube-reserved,system-reserved
EOF2

exit 0
EOF

RUN chmod +x /usr/local/bin/podnode-write-vcluster-flags.sh

# -----------------------------------------------------------------------------
# Watcher: wait for kubelet bootstrap to finish, then write flags & restart kubelet
# -----------------------------------------------------------------------------
RUN cat << 'EOF' > /usr/local/bin/podnode-allocatable-watcher.sh
#!/usr/bin/env bash
set -euo pipefail

KUBEADM_FLAGS="/var/lib/kubelet/kubeadm-flags.env"

# Wait up to ~5 minutes for kubelet + kubeadm-flags.env
for i in {1..300}; do
  if [[ -f "${KUBEADM_FLAGS}" ]] && systemctl status kubelet >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# If still not ready, bail (don’t block container startup)
if [[ ! -f "${KUBEADM_FLAGS}" ]]; then
  exit 0
fi

CPU_DESIRED_RAW="${PODNODE_CPU:-}"
MEM_DESIRED_RAW="${PODNODE_MEMORY:-}"
if [[ -z "${CPU_DESIRED_RAW}" || -z "${MEM_DESIRED_RAW}" ]]; then
  exit 0
fi

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

# Flags we want kubelet to run with
F1="--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki"
F2="--system-reserved=cpu=0m,memory=0Ki"
F3="--enforce-node-allocatable=pods,kube-reserved,system-reserved"

# Extract current args from kubeadm-flags.env
LINE="$(cat "${KUBEADM_FLAGS}")"
ARGS="$(printf "%s" "${LINE}" | sed -n 's/^KUBELET_KUBEADM_ARGS="\([^"]*\)".*$/\1/p')"
if [[ -z "${ARGS}" ]]; then
  exit 0
fi

NEW_ARGS="${ARGS}"
grep -q -- "${F1}" "${KUBEADM_FLAGS}" || NEW_ARGS="${NEW_ARGS} ${F1}"
grep -q -- "${F2}" "${KUBEADM_FLAGS}" || NEW_ARGS="${NEW_ARGS} ${F2}"
grep -q -- "${F3}" "${KUBEADM_FLAGS}" || NEW_ARGS="${NEW_ARGS} ${F3}"

# Write back only if changed, then restart kubelet once
if [[ "${NEW_ARGS}" != "${ARGS}" ]]; then
  printf 'KUBELET_KUBEADM_ARGS="%s"\n' "${NEW_ARGS}" > "${KUBEADM_FLAGS}"
  systemctl daemon-reload
  systemctl restart kubelet || true
fi

exit 0
EOF

RUN chmod +x /usr/local/bin/podnode-allocatable-watcher.sh

# -----------------------------------------------------------------------------
# Shim entrypoint: start watcher in background, then run original /entrypoint.sh
# -----------------------------------------------------------------------------
RUN cat << 'EOF' > /usr/local/bin/podnode-entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

# Start watcher in background (single-shot; exits on its own)
/usr/local/bin/podnode-allocatable-watcher.sh >/var/log/podnode-allocatable-watcher.log 2>&1 &

exec /entrypoint.sh
EOF

RUN chmod +x /usr/local/bin/podnode-entrypoint.sh

# Delete ubuntu user (ignore if missing)
RUN deluser ubuntu || true

STOPSIGNAL SIGRTMIN+3
ENV container=docker

# Use the shim entrypoint so the watcher always runs
CMD ["/usr/local/bin/podnode-entrypoint.sh"]
