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
   In Spacelift, navigate to Blueprints and create a new blueprint using the contents of `blueprints/quick-cluster.yaml`.

2. **Launch Stack**
   Create a stack from the blueprint, selecting your AWS region and instance configuration.

3. **One click, then hands-off**
   Launching the blueprint triggers the admin stack, which creates the child stacks and
   automatically kicks off the deployment chain. Every stack auto-deploys, so **no manual run
   confirmation is required** after the admin stack runs:

   `admin → OpenTofu → Ansible (k3s only) → Kubernetes`

4. **Access Cluster**
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

The cascade is fully automatic: `module.stack_opentofu` / `module.stack_ansible` set
`auto_deploy = true`, the Kubernetes stack sets `autodeploy = true`, and a `spacelift_run`
resource in the admin stack triggers the initial OpenTofu run (re-firing only when the run tag
changes). Stack dependencies propagate each completed run to the next stack.

## Private Workers + KEDA Autoscaling

Set **Deploy Private Workers to Cluster** ≥ 1 to auto-provision a Spacelift worker pool and deploy
the [Kubernetes worker controller](https://docs.spacelift.io/concepts/worker-pools/kubernetes-workers)
into the cluster. The admin stack mints the pool's CSR/token and hands the credentials to the
Kubernetes stack through the (locked-down, encrypted) S3 bucket.

Enable **Autoscale Worker Pool (KEDA)** to scale the pool on Spacelift queue depth instead of a
fixed size. This installs Spacelift's documented autoscaling path into the cluster:

```
spacelift-workerpool-controller (+ spacelift-promex exporter)
  → kube-prometheus-stack            (scrapes the exporter via a PodMonitor)
    → KEDA ScaledObject              (scales the WorkerPool CRD between min/max
                                      on spacelift_worker_pool_runs_pending)
```

- The admin stack creates a dedicated `spacelift_api_key` for the exporter and attaches it to the
  built-in `space-admin` role on the resource space. **The admin stack therefore needs admin
  access to the `root` Space** (required to resolve/attach system roles). Override the exporter
  endpoint with `spacelift_api_endpoint` if you are not on `https://<account>.app.spacelift.io`.
- `Min Workers` / `Max Workers` set the KEDA bounds (`Min Workers = 0` scales to zero when idle).
- All of the in-cluster wiring lives in `stacks/kubernetes/scripts/deploy-workers-keda.sh`,
  invoked from the Kubernetes stack's `after_apply` hook.

## EKS + Karpenter (when `cluster_type = eks`)

The EKS path provisions a current, autoscaling-ready cluster:

- **Kubernetes version** is set by `eks_cluster_version` (default `1.35`).
- A small **`m5.large` "system" managed node group** (2 nodes) bootstraps Karpenter and runs
  system/monitoring pods. All other workload capacity is provisioned elastically by **Karpenter**.
- **Karpenter** (`stacks/tofu/karpenter.tf`) is wired via EKS Pod Identity. The OpenTofu stack
  creates the controller/node IAM roles + SQS interruption queue and publishes
  `karpenter/config.json` to S3; the Kubernetes stack then installs the Karpenter Helm chart and a
  default `EC2NodeClass`/`NodePool` (`stacks/kubernetes/scripts/deploy-karpenter.sh`).
- The **EBS CSI driver** addon + a default **gp3 StorageClass** are installed so dynamic
  PersistentVolumes work — required by kube-prometheus-stack and by the self-hosted Spacelift
  chart's in-cluster MinIO/Postgres.

This makes the cluster a viable base for a self-hosted Spacelift install: pods that don't fit the
system pool cause Karpenter to add nodes on demand and consolidate them back when idle.

## Self-Hosted Spacelift (optional toggle)

Set **Install Self-Hosted Spacelift** = `true` to deploy a full self-hosted Spacelift instance
onto the cluster from the vendored umbrella chart at `stacks/kubernetes/selfhosted/` (the Spacelift
app — server/drain/scheduler/MQTT — plus in-cluster MinIO and Postgres). The toggle also installs
**ingress-nginx** and **cert-manager**. Recommended only with `cluster_type = eks` (Karpenter
provides the compute; gp3 EBS backs the MinIO/Postgres volumes).

The chart needs values that have no safe defaults (a Spacelift **license JWT**, backend/launcher
**images** from your entitlement, an **RSA encryption key**, admin/MinIO/Postgres passwords, your
**domain**). These are supplied out-of-band so they never touch git or Terraform state:

1. Enable the toggle and launch. The admin stack creates an auto-attached
   `<prefix>selfhosted-secrets` context.
2. Generate the RSA key (`stacks/kubernetes/selfhosted/scripts/gen-rsa-key.sh`) and fill in a copy
   of `stacks/kubernetes/selfhosted/values-secrets.example.yaml`.
3. In Spacelift, add that file to the secrets context as a **mounted file named
   `values-secrets.yaml`** (it lands at `/mnt/workspace/values-secrets.yaml`).
4. Re-run the Kubernetes stack. `deploy-selfhosted.sh` runs `helm upgrade --install … -f
   values-secrets.yaml --skip-schema-validation` (the `--skip-schema-validation` flag is required
   when the upstream chart runs as a subchart).
5. Point DNS for your `serverHostname` and MinIO host at the ingress-nginx load balancer, set the
   `cert-manager.io/cluster-issuer: letsencrypt` annotation in your values (if you supplied an ACME
   email), and complete first-time setup at `https://<serverHostname>/`.

If the toggle is on but no `values-secrets.yaml` is present, the script prints these instructions
and skips the install (no half-applied state).

## Configuration

See `stacks/admin/README.md` for detailed configuration options including:

- AWS region and subnet selection
- Instance type and volume configuration
- Worker pool assignment
- Private worker deployment and KEDA autoscaling (`enable_worker_autoscaling`, `min_workers`, `max_workers`)

## Requirements

- AWS: VPC with public subnet, IAM permissions for EC2/S3
- Spacelift: Administrative stack capability, AWS integration
