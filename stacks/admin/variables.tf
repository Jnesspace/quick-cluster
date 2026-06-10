variable "cluster_type" {
  type        = string
  description = "Type of Kubernetes cluster: 'k3s' (self-managed on EC2) or 'eks' (AWS managed)"
  default     = "k3s"

  validation {
    condition     = contains(["k3s", "eks"], var.cluster_type)
    error_message = "cluster_type must be either 'k3s' or 'eks'"
  }
}

variable "aws_integration_id" {
  type        = string
  description = "The AWS Integration to use for child stacks."
}

variable "resource_space_id" {
  type        = string
  description = "The Space ID to use for created resources."
}

variable "ansible_worker_pool_id" {
  type        = string
  description = "The worker pool ID to use for ansible jobs."
  default     = null # Use public worker pool
}

variable "worker_pool_id" {
  type        = string
  description = "The worker pool ID to use for all stacks."
  default     = null # Use public worker pool
}

variable "subnet_id" {
  type        = string
  description = "The subnet to launch instance in in the OpenTofu stack."
  default     = null
}

variable "aws_default_region" {
  type        = string
  description = "The default region to use for the AWS provider."
}

variable "create_new_subnet" {
  type        = bool
  description = "Whether to create a new subnet automatically for the OpenTofu stack."
  default     = false
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type used by the OpenTofu stack."
  default     = "t3.small"
}

variable "root_volume_size" {
  type        = number
  description = "Size of the root EBS volume in GB. Recommended: 50GB+ for Spacelift private workers."
  default     = 20
}

variable "root_volume_type" {
  type        = string
  description = "EBS volume type (gp2, gp3, io1, io2)."
  default     = "gp3"
}

variable "stack_prefix" {
  type        = string
  description = "Optional static prefix for all generated child stacks/contexts."
  default     = ""
}

variable "repo_branch" {
  type        = string
  description = "The branch to use for the repository"
  default     = "dev"
}

variable "ssh_key_name" {
  type        = string
  description = "Name of existing AWS EC2 Key Pair for SSH access to instances"
  default     = null
}

variable "run_tag" {
  type        = string
  description = "Unique run tag for this deployment, supplied by the Blueprint."
  default     = ""
}

variable "deploy_private_workers" {
  type        = string
  description = "Number of private workers to deploy to the K3s cluster (0-10, 0 = disabled)"
  default     = "0"

  validation {
    condition     = tonumber(var.deploy_private_workers) >= 0 && tonumber(var.deploy_private_workers) <= 10
    error_message = "deploy_private_workers must be between 0 and 10"
  }
}

variable "kubernetes_runner_image" {
  type        = string
  description = "Docker image to use for the Kubernetes stack runner"
  default     = "public.ecr.aws/o6n6e5l1/jakeskuberneteshelmrunner:latest"
}

#──────────────────────────────────────────────────────────────────────────────
# KEDA worker-pool autoscaling
#
# When enable_worker_autoscaling is true (and deploy_private_workers > 0) the
# Kubernetes stack installs the Spacelift Prometheus exporter, kube-prometheus-stack
# and KEDA, then scales the WorkerPool between min_workers and max_workers based on
# the spacelift_worker_pool_runs_pending queue-depth metric.
#──────────────────────────────────────────────────────────────────────────────
variable "enable_worker_autoscaling" {
  type        = bool
  description = "Autoscale the private worker pool with KEDA based on Spacelift queue depth."
  default     = false
}

variable "min_workers" {
  type        = number
  description = "Minimum number of workers KEDA keeps running (0 = scale to zero when idle)."
  default     = 1

  validation {
    condition     = var.min_workers >= 0
    error_message = "min_workers must be >= 0"
  }
}

variable "max_workers" {
  type        = number
  description = "Maximum number of workers KEDA will scale the pool up to."
  default     = 3

  validation {
    condition     = var.max_workers >= 1
    error_message = "max_workers must be >= 1"
  }
}

variable "spacelift_api_endpoint" {
  type        = string
  description = "Spacelift API endpoint for the Prometheus exporter (e.g. https://my-account.app.spacelift.io). Leave blank to derive it from the current account name."
  default     = ""
}

variable "eks_cluster_version" {
  type        = string
  description = "Kubernetes version for the EKS control plane and managed nodes (eks cluster_type only)."
  default     = "1.35"
}

variable "eks_admin_principal_arn" {
  type        = string
  description = "Optional IAM user/role ARN granted EKS cluster-admin (so an operator can use kubectl/Freelens). eks cluster_type only."
  default     = ""
}

#──────────────────────────────────────────────────────────────────────────────
# Self-hosted Spacelift (optional)
#
# When enabled, the Kubernetes stack installs the vendored self-hosted Spacelift
# umbrella chart (app + in-cluster MinIO + Postgres) plus ingress-nginx and
# cert-manager. Recommended only with cluster_type = eks (it needs real compute,
# which Karpenter provides). Secrets/license are supplied out-of-band via a
# mounted values-secrets.yaml on the auto-created secrets context.
#──────────────────────────────────────────────────────────────────────────────
variable "enable_selfhosted" {
  type        = bool
  description = "Install a full self-hosted Spacelift instance on the cluster."
  default     = false
}

variable "selfhosted_acme_email" {
  type        = string
  description = "Email for the Let's Encrypt ClusterIssuer used by the self-hosted ingress (blank = skip issuer; bring your own TLS)."
  default     = ""
}