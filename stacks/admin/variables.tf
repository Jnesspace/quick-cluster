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