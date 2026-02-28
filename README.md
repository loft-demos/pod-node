## Pod Node

Easy container to use as a Kubernetes node. Usage:
```bash
# Create pod node
kubectl apply -f https://raw.githubusercontent.com/FabianKramm/pod-node/refs/heads/main/deploy/node.yaml

# Exec into pod
kubectl exec -it pod-node -- bash

# Install required tools (containerd, kubelet etc.) and prepare host
curl -sfL https://raw.githubusercontent.com/loft-sh/init-node/main/init.sh | sh -s -- --kubernetes-version v1.32.1

# Join the pod into a cluster
kubeadm join --token <token> <control-plane-host>:<control-plane-port> --discovery-token-ca-cert-hash sha256:<hash>
```

### Node Sizing via Environment Variables

When `PODNODE_CPU` and `PODNODE_MEMORY` are set, pod-node adjusts kubelet
reserved resources so allocatable CPU/memory tracks those values.

When `PODNODE_PODS` is set to a positive integer, pod-node sets kubelet
`--max-pods` to that value.

Example:
```yaml
env:
  - name: PODNODE_CPU
    value: "2"
  - name: PODNODE_MEMORY
    value: "4Gi"
  - name: PODNODE_PODS
    value: "20"
```
