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

# Keep your existing entrypoint / files
COPY files /

# Script: compute kubelet reserves from PODNODE_CPU/PODNODE_MEMORY and write /etc/vcluster/vcluster-flags.env
RUN mkdir -p /usr/local/bin && \
    cat << 'EOF' > /usr/local/bin/podnode-write-kubelet-extra-args.sh
#!/usr/bin/env bash
set -euo pipefail

# Read container env vars robustly (systemd ExecStartPre may not inherit container env)
get_env() {
  local key="$1"
  # 1) try current process env
  local v="${!key:-}"
  if [[ -n "$v" ]]; then
    printf "%s" "$v"
    return 0
  fi
  # 2) try PID1 env (systemd)
  tr '\0' '\n' </proc/1/environ 2>/dev/null | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}'
}

CPU_DESIRED_RAW="$(get_env PODNODE_CPU || true)"
MEM_DESIRED_RAW="$(get_env PODNODE_MEMORY || true)"

# If not set, do nothing (keep default behavior)
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

# kubelet drop-in (10-kubeadm.conf) already sources this file:
#   EnvironmentFile=-/etc/vcluster/vcluster-flags.env
mkdir -p /etc/vcluster
cat > /etc/vcluster/vcluster-flags.env <<EOF2
KUBELET_EXTRA_ARGS="--kube-reserved=cpu=${RESERVE_CPU_M}m,memory=${RESERVE_MEM_KI}Ki --system-reserved=cpu=0m,memory=0Ki"
EOF2

exit 0
EOF

RUN chmod +x /usr/local/bin/podnode-write-kubelet-extra-args.sh

# Hook into kubelet startup (guaranteed to run, unlike boot targets in some container setups)
RUN mkdir -p /etc/systemd/system/kubelet.service.d && \
    cat << 'EOF' > /etc/systemd/system/kubelet.service.d/20-podnode-allocatable.conf
[Service]
ExecStartPre=/usr/local/bin/podnode-write-kubelet-extra-args.sh
EOF

# Delete ubuntu user (ignore if missing)
RUN deluser ubuntu || true

STOPSIGNAL SIGRTMIN+3
ENV container=docker

CMD ["/entrypoint.sh"]
