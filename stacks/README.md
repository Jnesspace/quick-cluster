# Stacks Overview

This directory contains the stacks that compose the Quick-Cluster workflow.

- `admin`: Administrative stack that orchestrates child stacks and shared resources
- `tofu`: OpenTofu stack that provisions EC2 instances
- `ansible`: Ansible stack that installs and configures the K3s cluster
- `kubernetes`: Kubernetes example workload applied to the cluster

Refer to each subdirectory README for usage and configuration details.
