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

variable "stack_prefix" {
  type        = string
  description = "Optional static prefix for all generated child stacks/contexts."
  default     = ""
}

variable "repo_branch" {
  type        = string
  description = "The branch to use for the repository"
  default     = "main"
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