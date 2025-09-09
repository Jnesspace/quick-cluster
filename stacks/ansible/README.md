# Ansible K3s Deployment Stack

This stack deploys a K3s Kubernetes cluster on the EC2 instances provisioned by the OpenTofu stack.

## Scope

- Installs K3s server on the first node; installs K3s agents on remaining nodes
- Configures networking (Flannel VXLAN)
- Outputs kubeconfig for access and validates cluster health

## Cluster Topology

- Server node: `tofu-dev-1` (Kubernetes API)
- Agent nodes: `tofu-dev-2`, `tofu-dev-3`
- K3s version: `v1.28.5+k3s1` (default; subject to change)

## Network and Security

Opened ports:

- 22/tcp (SSH)
- 6443/tcp (Kubernetes API)
- 8472/udp (Flannel VXLAN)
- 10250/tcp (Kubelet)
- 30000–32767/tcp (NodePort)

## Access

The playbook outputs kubeconfig. Save to your local config and verify access:

```bash
echo "KUBECONFIG_CONTENT" > ~/.kube/config
kubectl get nodes
kubectl get pods -A
```

## Files

- `playbook.yml`: K3s deployment tasks
- `tofusible.yml`: Dynamic inventory configuration
- `inventory_plugins/tofusible.py`: Inventory plugin reading OpenTofu outputs

## Configuration

Variables in `playbook.yml` control the deployment:

- `k3s_version`
- `k3s_token`
- Additional K3s flags as needed
