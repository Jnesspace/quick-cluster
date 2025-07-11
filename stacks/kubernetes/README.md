# Kubernetes Hello World Stack

This stack deploys a simple nginx hello world application to the K3s cluster created by the Ansible stack.

## What It Does

- **Downloads kubeconfig** from S3 bucket created by admin stack
- **Deploys nginx hello world** with custom welcome page
- **Exposes via NodePort** on port 30080
- **Provides cleanup** capability

## How It Works

1. **Pre-deployment**: Downloads kubeconfig from S3 and verifies cluster connectivity
2. **Deployment**: Applies Kubernetes manifests for nginx deployment and service
3. **Post-deployment**: Shows access instructions and service endpoints

## Accessing the Application

After deployment, you can access the hello world app via any EC2 instance public IP:

```bash
# Get EC2 instance public IPs
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=tofu-dev-*" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text

# Access hello world app
curl http://INSTANCE_IP:30080
```

## Files

- `manifests/` - Kubernetes YAML manifests
- `scripts/` - Helper scripts for kubeconfig setup
- `main.tf` - Spacelift stack configuration (added to admin stack)