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

Set **Install Self-Hosted Spacelift** = `true` (with `cluster_type = eks`) to deploy a full
self-hosted Spacelift instance from the vendored umbrella chart at `stacks/kubernetes/selfhosted/`
(the Spacelift app — server/drain/scheduler/MQTT — plus in-cluster MinIO and Postgres on gp3 EBS).
Defaults to **no-DNS / port-forward** access; set `selfhosted_acme_email` to instead install
ingress-nginx + cert-manager for a real hostname/TLS.

### One-time prerequisites (per AWS account — survive teardown)

The chart needs a Spacelift **license**, **container images**, and **secrets** that can't be
defaulted. Do these once; they live in ECR/SSM (outside the stack lifecycle) and are reused on
every deploy:

1. **Images → ECR** (needs the self-hosted release bundle + docker):
   `stacks/kubernetes/scripts/push-selfhosted-images.sh <ecr-registry> <region> <bundle>`
   → push `spacelift-backend`/`spacelift-launcher`, note the refs.
2. **Secrets → SSM**: fill a copy of `stacks/kubernetes/selfhosted/values-secrets.example.yaml`
   (license JWT, RSA key via `scripts/gen-rsa-key.sh`, passwords, the ECR image refs from step 1;
   for no-DNS keep `serverHostname: localhost:8080`, `objectStorage.publicUrl: http://localhost:9000`,
   ingress disabled). Then:
   `aws ssm put-parameter --type SecureString --name /spacelift-selfhosted/values-secrets --value file://values-secrets.yaml`

`deploy-selfhosted.sh` pulls those secrets from SSM at run time (or from a `values-secrets.yaml`
mounted file on the auto-created `<prefix>selfhosted-secrets` context). Nothing secret touches git
or Terraform state.

### Launch (one click)

Blueprint inputs: `cluster_type=eks`, `aws_default_region` matching where the ECR/SSM live,
`enable_selfhosted=true`, and `eks_admin_principal_arn` = your IAM user/role ARN (so you can reach
the cluster afterward). The cascade installs Karpenter, then the chart — no manual steps.

### Reach the UI

```bash
aws eks update-kubeconfig --name <run_tag>-eks --region <region>   # if not already
kubectl -n spacelift port-forward svc/spacelift-server 8080:80     # UI
kubectl -n spacelift port-forward svc/minio 9000:9000             # object up/downloads
# open http://localhost:8080  — login: admin / (admin.password from your values)
```

If the toggle is on but no secrets are found (SSM param or mounted file), the script prints
instructions and skips the install (no half-applied state).

### Workers (auto-registration)

Set **Auto-Register Self-Hosted Workers** = `true` to deploy in-cluster workers that **auto-register**
with the self-hosted instance — no manual pool, CSR, or token. The `spacelift-workerpool-controller`
creates and manages the pool itself when it finds a `spacelift-api-credentials` secret + a tokenless
`WorkerPool` CR (`deploy-selfhosted-workers.sh`). Workers run in `spacelift-workers` and reach the
server/MQTT over in-cluster service DNS (no load balancer).

One-time prerequisite: create a Spacelift **API key in the self-hosted instance** with the
**"Worker pool controller"** role, then store a JSON config in SSM:

```bash
aws ssm put-parameter --type SecureString --name /spacelift-selfhosted/workers --value '{
  "keyId":"<self-hosted api key id>",
  "keySecret":"<self-hosted api key secret>",
  "endpoint":"http://spacelift-server.spacelift.svc.cluster.local",
  "poolName":"selfhosted-workers",
  "poolSize":2,
  "launcherImage":"<acct>.dkr.ecr.<region>.amazonaws.com/spacelift-launcher:v5.1.2"
}'
```

## Configuration

See `stacks/admin/README.md` for detailed configuration options including:

- AWS region and subnet selection
- Instance type and volume configuration
- Worker pool assignment
- Private worker deployment and KEDA autoscaling (`enable_worker_autoscaling`, `min_workers`, `max_workers`)

## Requirements

- AWS: VPC with public subnet, IAM permissions for EC2/S3
- Spacelift: Administrative stack capability, AWS integration
