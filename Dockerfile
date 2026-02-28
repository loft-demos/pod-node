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

# Bring in pod-node files (entrypoint.sh and helper scripts)
COPY files /

RUN install -m 0755 /podnode-clamp-allocatable.sh /usr/local/bin/podnode-clamp-allocatable.sh && \
    install -m 0755 /podnode-entrypoint.sh /usr/local/bin/podnode-entrypoint.sh

# Delete ubuntu user (ignore if missing)
RUN deluser ubuntu || true

STOPSIGNAL SIGRTMIN+3
ENV container=docker

# Use the shim entrypoint so the watcher always runs
CMD ["/usr/local/bin/podnode-entrypoint.sh"]
