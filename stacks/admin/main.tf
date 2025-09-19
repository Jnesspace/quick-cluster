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

# Generate random string for run_tag if not provided
resource "random_string" "name_suffix" {
  count   = var.run_tag == "" ? 1 : 0
  length  = 5
  upper   = false
  special = false
}

# Generate random string for prefix if not provided
resource "random_string" "prefix_suffix" {
  count   = var.stack_prefix == "" ? 1 : 0
  length  = 6
  upper   = false
  special = false
}

locals {
  # Auto-generate prefix if not provided
  auto_prefix = var.stack_prefix != "" ? var.stack_prefix : "tofusible-${random_string.prefix_suffix[0].result}"
  name_prefix = "${local.auto_prefix}-"
  
  unique_tag = var.run_tag != "" ? var.run_tag : random_string.name_suffix[0].result
  unique_prefix = "${local.name_prefix}${local.unique_tag}-"
  run_tag       = trimsuffix(local.unique_prefix, "-")
  bucket_name   = lower(replace(local.unique_prefix, "-", ""))
}

module "stack_opentofu" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that creates EC2 Servers"
  name            = "${local.unique_prefix}TofusibleKube-OpenTofu"
  repository_name = "Quick-Cluster"  #UPDATE_TO_YOUR_VALUE
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

    # This is the subnet where the instances will be created (optional)
    TF_VAR_subnet_id = {
      value     = var.subnet_id
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

  labels            = ["${local.run_tag}-opentofu"]
  project_root      = "stacks/tofu"
  repository_branch = var.repo_branch

  # Use default worker pool for OpenTofu stack if provided
  worker_pool_id = var.worker_pool_id
}

module "stack_ansible" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that configures EC2 servers"
  name            = "${local.unique_prefix}TofusibleKube-Ansible"
  repository_name = "Quick-Cluster"  #UPDATE_TO_YOUR_VALUE
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

  labels            = ["${local.run_tag}-ansible"]
  project_root      = "stacks/ansible"
  repository_branch = var.repo_branch

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
        # Ensure AWS CLI is available on the worker
        "command -v aws >/dev/null 2>&1 || (python3 -m ensurepip --upgrade >/dev/null 2>&1 || true) && (python3 -m pip install --user --quiet awscli || true)",
        "export PATH=\"$HOME/.local/bin:$PATH\"",
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

  # Use default worker pool for Ansible stack
  worker_pool_id = var.worker_pool_id
}

# Stack dependency: Ansible stack depends on OpenTofu stack
resource "spacelift_stack_dependency" "ansible_depends_on_opentofu" {
  stack_id            = module.stack_ansible.id
  depends_on_stack_id = module.stack_opentofu.id
}

# Reference the inventory output from OpenTofu stack and pass as environment variable
resource "spacelift_stack_dependency_reference" "inventory_output" {
  stack_dependency_id = spacelift_stack_dependency.ansible_depends_on_opentofu.id
  output_name         = "inventory_tofu"
  input_name          = "TOFUSIBLE_INVENTORY"
}

# S3 bucket for storing kubeconfig
resource "aws_s3_bucket" "kubeconfig_storage" {
  bucket = "${local.bucket_name}-${random_id.bucket_suffix.hex}"
  # Allow Terraform to delete the bucket even if it still contains
  # versioned objects (required because we enabled versioning below).
  force_destroy = true
  
  tags = {
    Name        = "TofusibleKube Kubeconfig Storage"
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
  name         = "${local.unique_prefix}TofusibleKube-Kubernetes"
  space_id     = var.resource_space_id
  description  = "Stack that deploys hello world app to K3s cluster"

  repository   = "Quick-Cluster"  #UPDATE_TO_YOUR_VALUE
  branch       = var.repo_branch
  project_root = "stacks/kubernetes"

  kubernetes {
    kubernetes_workflow_tool = "KUBERNETES"
  }

  labels = ["${local.run_tag}-kubernetes"]
  enable_well_known_secret_masking = true
  github_action_deploy = false

  # Use default worker pool for Kubernetes stack if provided
  worker_pool_id = var.worker_pool_id

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

  labels = ["autoattach:${local.run_tag}-kubernetes"]

  space_id = var.resource_space_id

  # Runs before terraform init / kubernetes init
  before_init = [
    # ensure .kube dir exists
    "mkdir -p /mnt/workspace/.kube",

    # wait for kubeconfig to be uploaded by Ansible (handles timing/race)
    "until aws s3api head-object --bucket $KUBECONFIG_S3_BUCKET --key kubeconfig-latest.yaml >/dev/null 2>&1; do echo '⏳ Waiting for kubeconfig in s3://$KUBECONFIG_S3_BUCKET...'; sleep 10; done",

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
    "until aws s3api head-object --bucket $KUBECONFIG_S3_BUCKET --key kubeconfig-latest.yaml >/dev/null 2>&1; do echo '⏳ Waiting for kubeconfig in s3://$KUBECONFIG_S3_BUCKET...'; sleep 10; done",
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
