# Kubernetes Stack

Deploys workloads to the K3s cluster created by the Ansible stack.

## Functionality

- Retrieves kubeconfig from S3
- Applies Kubernetes manifests
- Deploys monitoring stack (Prometheus, Node Exporter, kube-state-metrics)

## Deployment Flow

1. **Pre-deployment**: Downloads kubeconfig from S3, verifies cluster connectivity
2. **Deployment**: Applies manifests from `manifests/` directory
3. **Post-deployment**: Outputs service endpoints and access instructions

## Included Workloads

### Hello World Application
- Nginx deployment with custom welcome page
- Exposed via NodePort 30080

### Prometheus Monitoring Stack
- Prometheus server (NodePort 30090)
- Node Exporter (DaemonSet)
- kube-state-metrics

See `manifests/MONITORING-README.md` for monitoring configuration details.

## Accessing Applications

```bash
# Get node IPs
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=tofu-dev-*" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text

# Hello World
curl http://<NODE_IP>:30080

# Prometheus UI
http://<NODE_IP>:30090
```

## Files

| Path | Description |
|------|-------------|
| `manifests/` | Kubernetes YAML manifests |
| `scripts/` | Helper scripts for kubeconfig setup |

## Runner Image

This stack uses a custom runner image (`public.ecr.aws/o6n6e5l1/jakeskuberneteshelmrunner:latest`) that includes:

- Helm
- spacectl
- kubectl (via base image)

The runner image can be overridden via the `kubernetes_runner_image` variable in the admin stack.
