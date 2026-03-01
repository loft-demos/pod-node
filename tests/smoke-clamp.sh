#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/files/podnode-clamp-allocatable.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/systemctl"

cat >"${MOCK_BIN}/nproc" <<'EOF'
#!/usr/bin/env bash
echo "8"
EOF
chmod +x "${MOCK_BIN}/nproc"

KUBEADM_FLAGS="${TMP_DIR}/kubeadm-flags.env"
cat >"${KUBEADM_FLAGS}" <<'EOF'
KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock --pod-infra-container-image=registry.k8s.io/pause:3.10"
EOF

PATH="${MOCK_BIN}:${PATH}" \
PODNODE_KUBEADM_FLAGS_PATH="${KUBEADM_FLAGS}" \
PODNODE_CPU="4" \
PODNODE_MEMORY="8Gi" \
PODNODE_PODS="30" \
PODNODE_HOST_CPU_CORES="8" \
PODNODE_HOST_MEM_KI="33554432" \
bash "${SCRIPT}"

grep -q -- '--kube-reserved=cpu=' "${KUBEADM_FLAGS}"
grep -q -- '--system-reserved=cpu=0m,memory=0Ki' "${KUBEADM_FLAGS}"
grep -q -- '--enforce-node-allocatable=pods,kube-reserved,system-reserved' "${KUBEADM_FLAGS}"
grep -q -- '--kube-reserved-cgroup=/kubelet.slice' "${KUBEADM_FLAGS}"
grep -q -- '--system-reserved-cgroup=/system.slice' "${KUBEADM_FLAGS}"
grep -q -- '--max-pods=30' "${KUBEADM_FLAGS}"

echo "smoke-clamp: PASS"
