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

### vCluster Platform Auto Nodes (Pod NodeProvider)

This image can be used by a vCluster Platform Auto Nodes Pod NodeProvider to
create pod-backed worker nodes.

For Auto Nodes, map your selected NodeType resources into container env vars:

```hcl
node_cpu  = tostring(var.vcluster.nodeType.spec.resources.cpu)
node_mem  = tostring(var.vcluster.nodeType.spec.resources.memory)
node_pods = tostring(var.vcluster.nodeType.spec.resources.pods)
```

Then pass them into the pod-node container:

```hcl
env {
  name  = "PODNODE_CPU"
  value = local.node_cpu
}
env {
  name  = "PODNODE_MEMORY"
  value = local.node_mem
}
env {
  name  = "PODNODE_PODS"
  value = local.node_pods
}
```

This keeps kubelet allocatable CPU/memory and max pod count aligned with the
NodeType selected by Karpenter/vCluster Platform.

Important: for kubelet node `capacity` to reflect NodeType CPU/memory, run the
pod-node container with matching `resources.requests` and `resources.limits`
(Guaranteed QoS) in your NodeProvider pod template.

Use this pattern:

```hcl
locals {
  node_cpu  = tostring(var.vcluster.nodeType.spec.resources.cpu)
  node_mem  = tostring(var.vcluster.nodeType.spec.resources.memory)
  node_pods = tostring(var.vcluster.nodeType.spec.resources.pods)
}

container {
  name  = "pod-node"
  image = var.image

  env {
    name  = "PODNODE_CPU"
    value = local.node_cpu
  }
  env {
    name  = "PODNODE_MEMORY"
    value = local.node_mem
  }
  env {
    name  = "PODNODE_PODS"
    value = local.node_pods
  }

  resources {
    requests = {
      cpu    = local.node_cpu
      memory = local.node_mem
    }
    limits = {
      cpu    = local.node_cpu
      memory = local.node_mem
    }
  }
}
```

Quick verification after a node joins:

```bash
kubectl get node <node-name> -o jsonpath='{.status.capacity.cpu}{" "}{.status.capacity.memory}{" "}{.status.capacity.pods}{"\n"}'
kubectl get node <node-name> -o jsonpath='{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{" "}{.status.allocatable.pods}{"\n"}'
```
