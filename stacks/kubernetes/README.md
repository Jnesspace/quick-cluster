# Kubernetes Stack

This stack contains Kubernetes manifests that will be deployed to the K3s cluster created by the OpenTofu and Ansible stacks.

## What It Does

- Deploys basic Kubernetes resources to the K3s cluster
- Managed by Spacelift using kubectl
- Depends on the K3s cluster being ready

## Files

- `main.tf` - Basic Terraform configuration (if needed for outputs)
- `manifests/` - Directory containing Kubernetes YAML manifests
- `README.md` - This file

## Dependencies

This stack depends on:
1. **OpenTofu stack** - Creates the EC2 instances
2. **Ansible stack** - Installs and configures K3s cluster
3. **Kubeconfig** - Access credentials from the K3s cluster

The admin stack will configure the dependency chain automatically.