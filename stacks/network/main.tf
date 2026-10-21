terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# The network stack lays down what the cluster stacks need before any server
# exists: a VPC with one public subnet, plus the SSH key pair and the S3 bucket
# the Ansible and Kubernetes stacks use. Downstream stacks receive subnet_id
# through a Spacelift stack dependency output reference (TF_VAR_subnet_id).

variable "run_tag" {
  type        = string
  description = "Tag used to name and identify this deployment's resources"
  default     = "saturn-head"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.42.0.0/16"
}

variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key registered as the EC2 key pair Ansible uses to reach the servers"
}

variable "aws_private_key_name" {
  type        = string
  description = "Name of the EC2 key pair (must match TF_VAR_aws_private_key_name on the OpenTofu stack)"
}

variable "kubeconfig_s3_bucket" {
  type        = string
  description = "Name of the S3 bucket Ansible uploads the kubeconfig to (must be globally unique)"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.run_tag}-vpc"
  }
}

# Public subnet: the k3s servers need public IPs so Ansible on a Spacelift
# worker can reach them over SSH.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.run_tag}-public"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.run_tag}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.run_tag}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_key_pair" "this" {
  key_name   = var.aws_private_key_name
  public_key = var.ssh_public_key
}

# force_destroy so tearing the stack down also removes uploaded kubeconfigs.
resource "aws_s3_bucket" "kubeconfig" {
  bucket        = var.kubeconfig_s3_bucket
  force_destroy = true

  tags = {
    Name = "${var.run_tag}-kubeconfig"
  }
}

resource "aws_s3_bucket_public_access_block" "kubeconfig" {
  bucket                  = aws_s3_bucket.kubeconfig.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_id" {
  description = "Pass to the OpenTofu stack as TF_VAR_subnet_id"
  value       = aws_subnet.public.id
}
