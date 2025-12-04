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
  default     = null  # Use public worker pool
}

variable "worker_pool_id" {
  type        = string
  description = "The worker pool ID to use for all stacks."
  default     = null  # Use public worker pool
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