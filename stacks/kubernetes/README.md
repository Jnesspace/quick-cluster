# Kubernetes Example Stack

This stack deploys an example nginx application to the K3s cluster provisioned by the Ansible stack.

## Function

- Retrieves kubeconfig from S3 as prepared by the Admin/Ansible workflow
- Applies deployment and service manifests
- Exposes the service via NodePort on TCP 30080

## Process

1. Pre-deployment: Download kubeconfig from S3 and validate connectivity
2. Deployment: Apply manifests under `manifests/`
3. Post-deployment: Provide service access details

## Access

Obtain an instance public IP and access the NodePort:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=tofu-dev-*" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text

curl http://INSTANCE_IP:30080
```

## Files

- `manifests/`: Kubernetes YAML manifests
- `scripts/`: Helper scripts for kubeconfig setup
- `main.tf`: Spacelift stack configuration
