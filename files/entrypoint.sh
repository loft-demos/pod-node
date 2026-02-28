#!/bin/bash

# disable unused systemd components
ln -sf /dev/null /etc/systemd/system/systemd-udevd.service
ln -sf /dev/null /etc/systemd/system/systemd-sysctl.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket
ln -sf /dev/null /etc/systemd/system/systemd-resolved.service
echo 'disable_network_activation: true' > /etc/cloud/cloud.cfg.d/98-disable-network-activation.cfg
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Keep systemd and kubelet inside the pod's cgroup so kubelet capacity reflects
# pod CPU/memory limits from container resources.
mkdir -p /sys/fs/cgroup/kubelet.slice || true

exec /lib/systemd/systemd
