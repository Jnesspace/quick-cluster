terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
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

variable "subnet_id" {
  type        = string
  description = "The subnet to use for the instances"
}

variable "vpc_security_group_id" {
  type        = string
  description = "The security groups to use for the instances"
}

provider "aws" {}

# Create a security group that allows SSH access
resource "aws_security_group" "tofusible_sg" {
  name_prefix = "tofusible-"
  description = "Security group for Tofusible instances"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tofusible-security-group"
  }
}

# Query AWS for subnet information
data "aws_subnet" "selected" {
  id = var.subnet_id
}

# Query AWS for VPC information
data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
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

###############################
## Create 3 AWS instances for dev environment only
###############################

resource "aws_instance" "tofu_dev_1" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = "t2.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]
  tags = {
    Name        = "tofu-dev-1"
    Environment = "dev"
    Role        = "k8s-node-1"
  }
}

resource "aws_instance" "tofu_dev_2" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = "t2.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]
  tags = {
    Name        = "tofu-dev-2"
    Environment = "dev"
    Role        = "k8s-node-2"
  }
}

resource "aws_instance" "tofu_dev_3" {
  ami                    = data.aws_ami.this.id
  key_name               = var.aws_private_key_name
  instance_type          = "t2.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.tofusible_sg.id]
  tags = {
    Name        = "tofu-dev-3"
    Environment = "dev"
    Role        = "k8s-node-3"
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
    vpc_id              = data.aws_vpc.selected.id
    vpc_cidr_block      = data.aws_vpc.selected.cidr_block
    subnet_id           = data.aws_subnet.selected.id
    subnet_cidr_block   = data.aws_subnet.selected.cidr_block
    availability_zone   = data.aws_subnet.selected.availability_zone
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