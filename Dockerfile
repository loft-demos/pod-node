FROM ubuntu:noble

ARG TARGETARCH

# Install deps (systemd, cloud-init, etc.)
RUN apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y \
      curl fuse binutils jq conntrack iptables strace \
      apt-transport-https iproute2 ca-certificates gpg \
      systemd systemd-sysv dbus cloud-init kmod && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /home

# Keep copying any existing files you already use (entrypoint, units, etc.)
COPY files /

# ---- Clamp script (writes kubelet extra args to the file kubelet already sources) ----
RUN mkdir -p /usr/local/bin && \
    cat << 'EOF' > /usr/local/bin/podnode-clamp-allocatable.sh
#!/usr/bin/env bash
set -euo pipefail

log() {
  # show up in: journalctl -u podnode-allocatable.service
  logger -t podnode-allocatable "$*"
}

# Fallback: systemd units sometimes don't inherit container env vars.
# Read the original container env from PID 1 (systemd) environment.
get_from_pid1_env() {
  local key="$1"
  tr '\0' '\n' </proc/1/environ 2>/dev/null | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}'
}

CPU_DESIRED_RAW="${PODNODE_CPU:-}"
MEM_DESIRED_RAW="${PODNODE_MEMORY:-}"

if [[ -z "${CPU_DESIRED_RAW}" ]]; then
  CPU_DESIRED_RAW="$(get_from_pid1_env PODNODE_CPU || true)"
fi
if [[ -z "${MEM_DESIRED_RAW}" ]]; then
  MEM_DESIRED_RAW="$(get_from_pid1_env PODNODE_MEMORY || true)"
fi

# If still not set, do nothing
if [[ -z "${CPU_DESIRED_RAW}" || -z "${MEM_DESIRED_RAW}" ]]; then
  log "PODNODE_CPU/PODNODE_MEMORY not found; skipping"
  exit 0
fi

log "Target allocatable from env: cpu=${CPU_DESIRED_RAW} mem=${MEM_DESIRED_RAW}"

# Wait for kubelet unit to exist (installed by vCluster Auto Nodes)
for i in {1..240}; do
  if systemctl list-unit-files | grep -q '^kubelet\.service'; then
    break
  fi
  sleep 1
done

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

log "Host: cpu=${HOST_CPU_CORES} memKi=${HOST_MEM_KI} -> reserve cpu=${RESERVE_CPU_M}m mem=${RESERVE_MEM_KI}Ki"

# kubelet drop-in 10-kubeadm.conf already sources this file:
#   EnvironmentFile=-/etc/vcluster/vcluster-flags.env
mkdir -p /etc/vcluster
cat > /etc/vcluster/vcluster-flags.env <<EOF2
KUBELET_EXTRA_ARGS="--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki --system-reserved=cpu=0m,memory=0Ki"
EOF2

log "Wrote /etc/vcluster/vcluster-flags.env"
systemctl daemon-reload
systemctl restart kubelet || true
log "Restarted kubelet"
EOF

RUN chmod +x /usr/local/bin/podnode-clamp-allocatable.sh

# ---- systemd unit ----
RUN mkdir -p /etc/systemd/system && \
    cat << 'EOF' > /etc/systemd/system/podnode-allocatable.service
[Unit]
Description=Clamp kubelet allocatable to PODNODE_CPU/PODNODE_MEMORY (workshop)
After=cloud-final.service kubelet.service
Wants=cloud-final.service kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/podnode-clamp-allocatable.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Enable service so it runs on boot
RUN systemctl enable podnode-allocatable.service

# Delete ubuntu user (ignore if missing)
RUN deluser ubuntu || true

# Let Docker know how to stop the container
STOPSIGNAL SIGRTMIN+3

# Tell systemd we’re in a container
ENV container=docker

# Launch systemd as PID 1
CMD ["/entrypoint.sh"]
