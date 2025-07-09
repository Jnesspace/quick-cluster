# Kubernetes Stack

This stack contains Kubernetes manifests that will be deployed to the K3s cluster created by the OpenTofu and Ansible stacks.

## What It Does

- Deploys Kubernetes resources using native YAML manifests
- Managed by Spacelift using kubectl (not Terraform)
- Depends on the K3s cluster being ready

## Files

- `manifests/` - Directory containing Kubernetes YAML manifests
  - `nginx-example.yaml` - Example nginx deployment with namespace and service
- `README.md` - This file

## Example Resources

The included `nginx-example.yaml` creates:
- **Namespace**: `tofusible` for organizing resources
- **Deployment**: 2 nginx replicas with resource limits
- **Service**: NodePort service exposing nginx on port 30080

## Dependencies

This stack depends on:
1. **OpenTofu stack** - Creates the EC2 instances
2. **Ansible stack** - Installs and configures K3s cluster
3. **Kubeconfig** - Access credentials from the K3s cluster

The admin stack will configure the dependency chain and provide the kubeconfig automatically.

## Testing Your Deployment

After deployment, you can test the nginx service:
```bash
# Access via any node's public IP
curl http://[NODE_PUBLIC_IP]:30080

# Or check the deployment
kubectl get pods -n tofusible
kubectl get svc -n tofusible
```