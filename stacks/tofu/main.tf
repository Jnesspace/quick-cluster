terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

variable "aws_private_key_name" {
  type        = string
  description = "The name of the private key in AWS to use for SSH"
}

variable "private_key_path" {
  type        = string
  description = "The path to the private key to use for SSH"
}

variable "create_new_subnet" {
  type        = bool
  description = "Whether to create a new public subnet automatically. If true, var.subnet_id is ignored."
  default     = false
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type to use for cluster nodes."
  default     = "t3.small"
}

variable "subnet_id" {
  type        = string
  description = "The subnet to use for the instances (ignored when create_new_subnet=true)"
  default     = null
}

provider "aws" {}

# --- Added: default VPC lookup and optional subnet creation -------------------
# Look up the default VPC so we can place the generated subnet inside it when
# `var.create_new_subnet` is true.
data "aws_vpc" "default" {
  default = true
}

# Create a new public subnet if requested. When `create_new_subnet` is false the
# count is zero, so **no subnet is created** and downstream references to
# `aws_subnet.generated[0]` are ignored by conditionals.
resource "aws_subnet" "generated" {
  count                   = var.create_new_subnet ? 1 : 0
  vpc_id                  = data.aws_vpc.default.id
  # Choose a /24 far away from the typical default /20 ranges (0,16,32,48, etc.)
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 200) # 172.31.200.0/24 within default VPC
  map_public_ip_on_launch = true

  tags = {
    Name = "tofusible-generated"
  }
}
# -----------------------------------------------------------------------------

# Create a security group that allows SSH and K3s traffic
resource "aws_security_group" "tofusible_sg" {
  name_prefix = "tofusible-k3s-"
  description = "Security group for TofusibleKube K3s cluster"
  vpc_id      = local.vpc_id_final

  # Force replacement instead of in-place updates that can cause issues
  lifecycle {
    create_before_destroy = true
  }

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API server
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K3s server port (for agent registration)
  ingress {
    description = "K3s server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    self        = true
  }

  # Flannel VXLAN
  ingress {
    description = "Flannel VXLAN"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
  }

  # Kubelet metrics
  ingress {
    description = "Kubelet metrics"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  # NodePort services range
  ingress {
    description = "NodePort services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All traffic within security group
  ingress {
    description = "All internal traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tofusible-k3s-security-group"
  }
}

# Query AWS for subnet information
data "aws_subnet" "selected" {
  count = var.create_new_subnet ? 0 : 1
  id    = var.subnet_id
}

locals {
  subnet_id_final = var.create_new_subnet ? aws_subnet.generated[0].id : var.subnet_id
  vpc_id_final    = var.create_new_subnet ? data.aws_vpc.default.id : element(data.aws_subnet.selected.*.vpc_id, 0)
}

# Query AWS for availability zone information
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "this" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Generate a timestamp to force instance recreation on each deployment
resource "time_static" "deployment_time" {}

###############################
## Create 3 AWS instances for dev environment only
###############################

resource "aws_instance" "tofu_dev_1" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id_final
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]

  # Force recreation on each deployment
  lifecycle {
    replace_triggered_by = [
      time_static.deployment_time
    ]
  }

  tags = {
    Name         = "tofu-dev-1"
    Environment  = "dev"
    Role         = "k8s-node-1"
    DeploymentId = time_static.deployment_time.unix
  }
}

resource "aws_instance" "tofu_dev_2" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id_final
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]

  # Force recreation on each deployment
  lifecycle {
    replace_triggered_by = [
      time_static.deployment_time
    ]
  }

  tags = {
    Name         = "tofu-dev-2"
    Environment  = "dev"
    Role         = "k8s-node-2"
    DeploymentId = time_static.deployment_time.unix
  }
}

resource "aws_instance" "tofu_dev_3" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id_final
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]

  # Force recreation on each deployment
  lifecycle {
    replace_triggered_by = [
      time_static.deployment_time
    ]
  }

  tags = {
    Name         = "tofu-dev-3"
    Environment  = "dev"
    Role         = "k8s-node-3"
    DeploymentId = time_static.deployment_time.unix
  }
}

##############################################################
## Add dev nodes to the inventory
##############################################################
module "host_tofu_dev_1" {
  source  = "spacelift.io/spacelift-solutions/tofusible-host/spacelift"
  version = "1.0.0"

  host                 = aws_instance.tofu_dev_1.public_ip
  user                 = "ubuntu"
  ssh_private_key_file = var.private_key_path
  groups               = ["tofu", "dev", "k8s_nodes"]
  extra_vars = {
    node_role    = "k8s-node-1"
    private_ip   = aws_instance.tofu_dev_1.private_ip
    instance_id  = aws_instance.tofu_dev_1.id
  }
}

module "host_tofu_dev_2" {
  source  = "spacelift.io/spacelift-solutions/tofusible-host/spacelift"
  version = "1.0.0"

  host                 = aws_instance.tofu_dev_2.public_ip
  user                 = "ubuntu"
  ssh_private_key_file = var.private_key_path
  groups               = ["tofu", "dev", "k8s_nodes"]
  extra_vars = {
    node_role    = "k8s-node-2"
    private_ip   = aws_instance.tofu_dev_2.private_ip
    instance_id  = aws_instance.tofu_dev_2.id
  }
}

module "host_tofu_dev_3" {
  source  = "spacelift.io/spacelift-solutions/tofusible-host/spacelift"
  version = "1.0.0"

  host                 = aws_instance.tofu_dev_3.public_ip
  user                 = "ubuntu"
  ssh_private_key_file = var.private_key_path
  groups               = ["tofu", "dev", "k8s_nodes"]
  extra_vars = {
    node_role    = "k8s-node-3"
    private_ip   = aws_instance.tofu_dev_3.private_ip
    instance_id  = aws_instance.tofu_dev_3.id
  }
}

############################################################################################
## Output the inventory and AWS information
############################################################################################
output "inventory_tofu" {
  value = [
    module.host_tofu_dev_1.spec,
    module.host_tofu_dev_2.spec,
    module.host_tofu_dev_3.spec
  ]
  sensitive = true
}

# Output AWS information for reference
output "aws_info" {
  value = {
    vpc_id              = local.vpc_id_final
    vpc_cidr_block      = var.create_new_subnet ? data.aws_vpc.default.cidr_block : data.aws_subnet.selected[0].cidr_block
    subnet_id           = local.subnet_id_final
    subnet_cidr_block   = var.create_new_subnet ? aws_subnet.generated[0].cidr_block : data.aws_subnet.selected[0].cidr_block
    availability_zone   = var.create_new_subnet ? aws_subnet.generated[0].availability_zone : data.aws_subnet.selected[0].availability_zone
    security_group_id   = aws_security_group.tofusible_sg.id
    security_group_name = aws_security_group.tofusible_sg.name
    ami_id              = data.aws_ami.this.id
    ami_name            = data.aws_ami.this.name
    available_azs       = data.aws_availability_zones.available.names
  }
}

# Output instance information
output "instances_info" {
  value = {
    dev_1 = {
      id         = aws_instance.tofu_dev_1.id
      public_ip  = aws_instance.tofu_dev_1.public_ip
      private_ip = aws_instance.tofu_dev_1.private_ip
      az         = aws_instance.tofu_dev_1.availability_zone
    }
    dev_2 = {
      id         = aws_instance.tofu_dev_2.id
      public_ip  = aws_instance.tofu_dev_2.public_ip
      private_ip = aws_instance.tofu_dev_2.private_ip
      az         = aws_instance.tofu_dev_2.availability_zone
    }
    dev_3 = {
      id         = aws_instance.tofu_dev_3.id
      public_ip  = aws_instance.tofu_dev_3.public_ip
      private_ip = aws_instance.tofu_dev_3.private_ip
      az         = aws_instance.tofu_dev_3.availability_zone
    }
  }
}