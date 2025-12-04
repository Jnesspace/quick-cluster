# Quick-Cluster

Automated 3-node K3s cluster deployment on AWS using Spacelift, OpenTofu, and Ansible.

## Overview

This repository provides a complete infrastructure-as-code solution for deploying a K3s Kubernetes cluster on AWS EC2 instances. The deployment is orchestrated through Spacelift using a multi-stack architecture:

- **OpenTofu** provisions EC2 instances and networking
- **Ansible** installs and configures K3s
- **Kubernetes** deploys workloads to the cluster

## Quick Start

### Prerequisites

- AWS account with appropriate permissions
- Spacelift account with AWS integration configured
- Fork of this repository

### Deployment

1. **Create Blueprint**
   In Spacelift, navigate to Blueprints and create a new blueprint using the contents of `blueprints/tofusible-admin.yaml`.

2. **Launch Stack**
   Create a stack from the blueprint, selecting your AWS region and instance configuration.

3. **Access Cluster**
   After deployment completes (~10 minutes), retrieve the kubeconfig:
   ```bash
   aws s3 cp s3://<bucket>/kubeconfig-latest.yaml ~/.kube/config
   kubectl get nodes
   ```

## Repository Structure

```
blueprints/              # Spacelift blueprint definition
modules/tofusible_host/  # OpenTofu module for inventory normalization
stacks/
  admin/                 # Administrative stack (orchestration)
  tofu/                  # OpenTofu stack (infrastructure)
  ansible/               # Ansible stack (K3s installation)
  kubernetes/            # Kubernetes stack (workload deployment)
```

## Architecture

1. **Admin Stack** creates shared resources (S3 bucket, SSH keys) and child stacks
2. **OpenTofu Stack** provisions 3 EC2 instances and outputs inventory data
3. **Ansible Stack** consumes inventory, installs K3s, uploads kubeconfig to S3
4. **Kubernetes Stack** retrieves kubeconfig and deploys manifests

All stacks share a unique run tag for isolation, enabling parallel deployments without conflicts.

## Configuration

See `stacks/admin/README.md` for detailed configuration options including:

- AWS region and subnet selection
- Instance type and volume configuration
- Worker pool assignment
- Private worker deployment

## Requirements

- AWS: VPC with public subnet, IAM permissions for EC2/S3
- Spacelift: Administrative stack capability, AWS integration
