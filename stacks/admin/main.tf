terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    spacelift = {
      source = "spacelift-io/spacelift"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "aws" {
  region = var.aws_default_region
}

provider "spacelift" {}

resource "random_string" "name_suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name_prefix = (
    var.stack_prefix != "" ? "${var.stack_prefix}-" : ""
  )
  unique_prefix = "${local.name_prefix}${random_string.name_suffix.result}-"
  run_tag       = trimsuffix(local.unique_prefix, "-")
}

module "stack_opentofu" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that creates EC2 Servers"
  name            = "${local.unique_prefix}Tofusible - OpenTofu"
  repository_name = "Quick-Cluster"
  space_id        = var.resource_space_id

  auto_deploy = true

  aws_integration = {
    enabled = true
    id      = var.aws_integration_id
  }

  environment_variables = {
    # We pass this to the OpenTofu stack so it can be used in the inventory
    TF_VAR_private_key_path = {
      value     = local.private_key_full_path
      sensitive = false
    }

    # We pass this to the OpenTofu stack so it can be used in the aws ec2 instances
    TF_VAR_aws_private_key_name = {
      value     = aws_key_pair.this.key_name
      sensitive = false
    }

    # This is the subnet where the instances will be created
    TF_VAR_subnet_id = {
      value     = var.subnet_id
      sensitive = false
    }

    TF_VAR_create_new_subnet = {
      value     = tostring(var.create_new_subnet)
      sensitive = false
    }

    TF_VAR_instance_type = {
      value     = var.instance_type
      sensitive = false
    }

    AWS_DEFAULT_REGION = {
      value     = var.aws_default_region
      sensitive = false
    }
  }

  contexts = {
    tofusible_ssh_key = spacelift_context.ssh_keys.id
  }

  labels            = ["tofusible", "opentofu", "infracost", "run/${local.run_tag}"]
  project_root      = "stacks/tofu"
  repository_branch = "main"
}

module "stack_ansible" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that configures EC2 servers"
  name            = "${local.unique_prefix}Tofusible - Ansible"
  repository_name = "Quick-Cluster"
  space_id        = var.resource_space_id

  auto_deploy = true

  aws_integration = {
    enabled = true
    id      = var.aws_integration_id
  }

  environment_variables = {
    # !IMPORTANT
    # This variable tells ansible where to find the inventory file
    ANSIBLE_INVENTORY = {
      value     = "tofusible.yml"
      sensitive = false
    }
    
    # S3 bucket for kubeconfig storage
    KUBECONFIG_S3_BUCKET = {
      value     = aws_s3_bucket.kubeconfig_storage.bucket
      sensitive = false
    }
    
    AWS_DEFAULT_REGION = {
      value     = var.aws_default_region
      sensitive = false
    }
  }

  contexts = {
    # We attach the ssh key to the stack so ansible can use it to connect to the servers
    tofusible_ssh_key = spacelift_context.ssh_keys.id
  }

  labels            = ["tofusible", "ansible", "run/${local.run_tag}"]
  project_root      = "stacks/ansible"
  repository_branch = "main"

  workflow_tool    = "ANSIBLE"
  ansible_playbook = "playbook.yml"

  hooks = {
    before = {
      # !IMPORTANT
      # WE *must* chmod the tofusible.yml and private key files for ansible to use them.
      init  = ["chmod 644 tofusible.yml", "chmod 600 ${local.private_key_full_path}"]
      apply = ["chmod 644 tofusible.yml", "chmod 600 ${local.private_key_full_path}"]
    }
    
    after = {
      apply = [
        "echo '🔍 Checking for kubeconfig files...'",
        "ls -la /tmp/kubeconfig* || echo 'No kubeconfig files found'",
        "echo '📄 Contents of kubeconfig if found:'",
        "test -f /tmp/kubeconfig-ready.yaml && head -20 /tmp/kubeconfig-ready.yaml || echo 'No kubeconfig to display'",
        "test -f /tmp/kubeconfig-ready.yaml && echo '✅ Found kubeconfig, uploading to S3...' || echo '❌ Kubeconfig not found'",
        "test -f /tmp/kubeconfig-ready.yaml && aws s3 cp /tmp/kubeconfig-ready.yaml s3://$KUBECONFIG_S3_BUCKET/kubeconfig-$(date +%Y%m%d-%H%M%S).yaml && echo '📤 Timestamped version uploaded' || true",
        "test -f /tmp/kubeconfig-ready.yaml && aws s3 cp /tmp/kubeconfig-ready.yaml s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml && echo '📤 Latest version uploaded' || true",
        "test -f /tmp/kubeconfig-ready.yaml && echo '🎉 Kubeconfig available at: s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml' || echo '⚠️ Kubeconfig upload skipped'",
        "test -f /tmp/kubeconfig-ready.yaml && echo '💾 Download with: aws s3 cp s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml ~/.kube/config' || true"
      ]
    }
  }

  worker_pool_id = var.ansible_worker_pool_id

  dependencies = {
    # Pass the inventory from the OpenTofu stack to the Ansible stack
    TOFUSIBLE = {
      parent_stack_id = module.stack_opentofu.id

      references = {
        # NOTE: This output is *sensitive* as it could hold passwords
        # If you want to use this on a private worker you *MUST* enable sensitive output uploading.
        # This example utilizes a public worker to create the output (see the stack_tofu above)
        # and public workers do not require that setting.
        # See more: https://docs.spacelift.io/concepts/stack/stack-dependencies#enabling-sensitive-outputs-for-references
        INVENTORY = {
          trigger_always = true
          # This is the name of the output in the OpenTofu stack that holds the host information
          output_name = "inventory_tofu"
          # This input name is reference in the `tofusible.yml` file
          # It tells the dynamic inventory where to get information about the hosts
          # Created in OpenTofu
          input_name = "TOFUSIBLE_INVENTORY"
        }
      }
    }
  }
}

# S3 bucket for storing kubeconfig
resource "aws_s3_bucket" "kubeconfig_storage" {
  bucket = "tofusible-kubeconfig-${random_id.bucket_suffix.hex}"
  
  tags = {
    Name        = "Tofusible Kubeconfig Storage"
    Environment = "dev"
    Purpose     = "kubeconfig-storage"
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_versioning" "kubeconfig_versioning" {
  bucket = aws_s3_bucket.kubeconfig_storage.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kubeconfig_encryption" {
  bucket = aws_s3_bucket.kubeconfig_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Output S3 bucket information
output "kubeconfig_s3_info" {
  value = {
    bucket_name = aws_s3_bucket.kubeconfig_storage.bucket
    latest_url  = "s3://${aws_s3_bucket.kubeconfig_storage.bucket}/kubeconfig-latest.yaml"
    download_command = "aws s3 cp s3://${aws_s3_bucket.kubeconfig_storage.bucket}/kubeconfig-latest.yaml ~/home/spacelift/.kube/config"
  }
  description = "S3 bucket information for kubeconfig storage"
}



resource "spacelift_stack" "tofusible-kubernetes" {
  name         = "${local.unique_prefix}Tofusible - Kubernetes"
  space_id     = var.resource_space_id
  description  = "Stack that deploys hello world app to K3s cluster"

  repository   = "Quick-Cluster"
  branch       = "main"
  project_root = "stacks/kubernetes"

  kubernetes {
    kubernetes_workflow_tool = "KUBERNETES"
  }

  labels = ["tofusible", "kubernetes", "autoattach:${local.run_tag}", "run/${local.run_tag}"]
  enable_well_known_secret_masking = true
  github_action_deploy = false

  # Remove the hooks block here, as hooks are now managed by spacelift_hook resources
}

# AWS Integration attachment for Kubernetes stack
resource "spacelift_aws_integration_attachment" "kubernetes" {
  integration_id = var.aws_integration_id
  stack_id       = spacelift_stack.tofusible-kubernetes.id
  read           = true
  write          = true
}

# Environment variables for Kubernetes stack
resource "spacelift_environment_variable" "kubernetes_s3_bucket" {
  stack_id = spacelift_stack.tofusible-kubernetes.id
  name     = "KUBECONFIG_S3_BUCKET"
  value    = aws_s3_bucket.kubeconfig_storage.bucket
}

resource "spacelift_environment_variable" "kubernetes_aws_region" {
  stack_id = spacelift_stack.tofusible-kubernetes.id
  name     = "AWS_DEFAULT_REGION"
  value    = var.aws_default_region
}

resource "spacelift_environment_variable" "kubernetes_kubeconfig" {
  stack_id = spacelift_stack.tofusible-kubernetes.id
  name     = "KUBECONFIG"
  value    = "/home/spacelift/.kube/config"
}

# Dependency on Ansible stack
resource "spacelift_stack_dependency" "kubernetes_depends_on_ansible" {
  stack_id            = spacelift_stack.tofusible-kubernetes.id
  depends_on_stack_id = module.stack_ansible.id
}

# Define a reusable Context that downloads your kubeconfig from S3
resource "spacelift_context" "kubeconfig_hooks" {
  name        = "${local.unique_prefix}kubeconfig-hooks"
  description = "Downloads the K3s kubeconfig before init and apply"

  labels = ["tofusible", "autoattach:${local.run_tag}"]

  # Runs before terraform init / kubernetes init
  before_init = [
    # ensure .kube dir exists
    "mkdir -p /mnt/workspace/.kube",

    # pull the latest kubeconfig
    "aws s3 cp s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml /mnt/workspace/.kube/config",

    # tighten permissions
    "chmod 600 /mnt/workspace/.kube/config",

    # debug output
    "echo '📥 Downloaded kubeconfig from S3:'",
    "head -20 /mnt/workspace/.kube/config",
  ]

  # Runs before terraform apply / kubernetes apply
  before_apply = [
    "mkdir -p /mnt/workspace/.kube",
    "aws s3 cp s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml /mnt/workspace/.kube/config",
    "chmod 600 /mnt/workspace/.kube/config",
    "echo '📥 Downloaded kubeconfig from S3:'",
    "head -20 /mnt/workspace/.kube/config",
  ]
}

# Attach that Context to your Kubernetes stack
resource "spacelift_context_attachment" "tofusible_k8s_hooks" {
  context_id = spacelift_context.kubeconfig_hooks.id
  stack_id   = spacelift_stack.tofusible-kubernetes.id
}