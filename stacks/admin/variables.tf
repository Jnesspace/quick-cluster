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

variable "subnet_id" {
  type        = string
  description = "Optional: existing subnet ID. If empty, the OpenTofu stack will auto-select a default subnet."
  default     = ""
}

variable "aws_default_region" {
  type        = string
  description = "The default region to use for the AWS provider."
}

// NOTE: create_new_subnet is deprecated/unused. Always use existing subnet via var.subnet_id.

variable "instance_type" {
  type        = string
  description = "EC2 instance type used by the OpenTofu stack."
  default     = "t3.small"
}

variable "stack_prefix" {
  type        = string
  description = "Optional static prefix for all generated child stacks/contexts."
  default     = ""
}

variable "repo_branch" {
  type        = string
  description = "Git branch in this repository to use for all child stacks."
  default     = "main"
}

variable "run_tag" {
  type        = string
  description = "Unique run tag for this deployment, supplied by the Blueprint."
  default     = ""
}