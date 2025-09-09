# Quick-Cluster

Quick-Cluster provisions a three-node K3s cluster on AWS EC2 using Spacelift. It composes OpenTofu (infrastructure), Ansible (K3s installation), and Kubernetes (sample workload) into an automated workflow. The kubeconfig is stored in S3 for retrieval.

## Prerequisites

- AWS account with programmatic access
- Spacelift account with AWS integration configured
- A fork or copy of this repository

## Deployment via Spacelift Blueprint

1. In Spacelift, open Blueprints and create a new blueprint.
2. Load `blueprints/tofusible-admin.yaml` from this repository and publish the blueprint.
3. Create a stack from the blueprint. Provide values for region, subnet ID, and target space as required by the stack variables.
4. Trigger a run. Provisioning completes in approximately 10–15 minutes.
5. Retrieve kubeconfig from the S3 bucket output and verify access:

   ```bash
   aws s3 cp s3://<bucket>/kubeconfig-latest.yaml ~/.kube/config
   kubectl get nodes
   ```

## Architecture

- Admin stack: Orchestrates child stacks, creates an S3 bucket for kubeconfig, and an SSH key context.
- OpenTofu stack: Provisions three EC2 instances and outputs inventory data.
- Ansible stack: Installs K3s (one server, two agents) and writes kubeconfig to S3.
- Kubernetes stack: Downloads kubeconfig and deploys example manifests.

A unique run tag isolates resources between runs and spaces.

## Repository Structure

```
blueprints/              # Spacelift blueprint definition(s)
modules/tofusible_host/  # OpenTofu module to normalize inventory output
stacks/
  admin/                 # Administrative stack that creates/links child stacks
  tofu/                  # OpenTofu stack – EC2 provisioning
  ansible/               # Ansible stack – installs and configures K3s
  kubernetes/            # Kubernetes stack – example workload
```

Refer to each subdirectory README for implementation details and configuration inputs.

## Inputs and Configuration

Configure the Admin stack with the following environment variables and inputs in Spacelift (variable names may be prefixed as required by your workflow):

- `AWS_DEFAULT_REGION` and `TF_VAR_aws_default_region`
- `TF_VAR_aws_integration_id`
- `TF_VAR_resource_space_id`
- `TF_VAR_subnet_id`
- `TF_VAR_run_tag` (set automatically by the blueprint)

See `stacks/admin/README.md` for details.

## Access and Operations

After provisioning completes, download the kubeconfig from S3 and use `kubectl` to access the cluster. The Ansible stack opens the minimal set of ports required for cluster operation. Example workloads are provided in `stacks/kubernetes/manifests`.

## Cleanup

Destroy the OpenTofu stack from Spacelift to remove the EC2 instances and related infrastructure. Ensure dependent resources are not in use before destroy operations.
