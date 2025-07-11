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

module "stack_opentofu" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that creates EC2 Servers"
  name            = "Tofusible - OpenTofu"
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

    AWS_DEFAULT_REGION = {
      value     = var.aws_default_region
      sensitive = false
    }
  }

  contexts = {
    tofusible_ssh_key = spacelift_context.ssh_keys.id
  }

  labels            = ["tofusible", "opentofu", "infracost"]
  project_root      = "stacks/tofu"
  repository_branch = "main"
}

module "stack_ansible" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that configures EC2 servers"
  name            = "Tofusible - Ansible"
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

  labels            = ["tofusible", "ansible"]
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

module "stack_kubernetes" {
  source = "spacelift.io/spacelift-solutions/stacks-module/spacelift"

  description     = "Stack that deploys hello world app to K3s cluster"
  name            = "Tofusible - Kubernetes"
  repository_name = "Quick-Cluster"
  space_id        = var.resource_space_id

  auto_deploy = true

  aws_integration = {
    enabled = true
    id      = var.aws_integration_id
  }

  environment_variables = {
    # S3 bucket for kubeconfig access
    KUBECONFIG_S3_BUCKET = {
      value     = aws_s3_bucket.kubeconfig_storage.bucket
      sensitive = false
    }
    
    AWS_DEFAULT_REGION = {
      value     = var.aws_default_region
      sensitive = false
    }
  }
  kubectl_version = "1.33.2"
  labels            = ["tofusible", "kubernetes"]
  project_root      = "stacks/kubernetes"
  repository_branch = "main"


  hooks = {
    before = {
      init  = ["chmod +x scripts/setup-kubeconfig.sh", "./scripts/setup-kubeconfig.sh"]
      apply = ["chmod +x scripts/setup-kubeconfig.sh", "./scripts/setup-kubeconfig.sh"]
    }
    
    after = {
      apply = [
        "echo '🎉 Hello World application deployed!'",
        "echo '📋 Deployment Status:'",
        "kubectl get deployments",
        "kubectl get services",
        "kubectl get pods",
        "echo ''",
        "echo '🌐 Access your application:'",
        "echo 'Get EC2 public IPs:'",
        "echo 'aws ec2 describe-instances --filters \"Name=tag:Name,Values=tofu-dev-*\" --query \"Reservations[].Instances[].PublicIpAddress\" --output text'",
        "echo ''",
        "echo 'Then visit: http://INSTANCE_IP:30080'",
        "echo '🚀 Your K3s cluster is ready with hello world app!'"
      ]
    }
  }

  dependencies = {
    # Simple dependency on Ansible stack completion - no output references needed
    ANSIBLE_COMPLETE = {
      parent_stack_id = module.stack_ansible.id
      # No references block needed - just wait for Ansible stack to complete
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
    download_command = "aws s3 cp s3://${aws_s3_bucket.kubeconfig_storage.bucket}/kubeconfig-latest.yaml ~/.kube/config"
  }
  description = "S3 bucket information for kubeconfig storage"
}