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
    tls = {
      source = "hashicorp/tls"
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
  # Cluster type booleans for clean conditionals
  is_k3s = var.cluster_type == "k3s"
  is_eks = var.cluster_type == "eks"

  # Auto-generate prefix if not provided
  auto_prefix = var.stack_prefix != "" ? var.stack_prefix : "tofusible-${random_string.prefix_suffix[0].result}"
  name_prefix = "${local.auto_prefix}-"

  unique_tag    = var.run_tag != "" ? var.run_tag : random_string.name_suffix[0].result
  unique_prefix = "${local.name_prefix}${local.unique_tag}-"
  run_tag       = trimsuffix(local.unique_prefix, "-")
  # RFC 1123 compliant name for Kubernetes resources (lowercase, alphanumeric, hyphens)
  run_tag_k8s = lower(local.run_tag)
  bucket_name = lower(replace(local.unique_prefix, "-", ""))
}

module "stack_opentofu" {
  source  = "spacelift.io/spacelift-solutions/stacks-module/spacelift"
  version = "~> 3.1"

  description     = "Stack that creates EC2 Servers"
  name            = "${local.unique_prefix}TofusibleKube-OpenTofu"
  repository_name = "Quick-Cluster" #UPDATE_TO_YOUR_VALUE
  space_id        = var.resource_space_id

  auto_deploy = true

  aws_integration = {
    enabled = true
    id      = var.aws_integration_id
  }

  environment_variables = {
    # Cluster type selection (k3s or eks)
    TF_VAR_cluster_type = {
      value     = var.cluster_type
      sensitive = false
    }

    # Run tag for resource naming
    TF_VAR_run_tag = {
      value     = local.run_tag
      sensitive = false
    }

    # S3 bucket for kubeconfig (EKS uploads directly)
    TF_VAR_kubeconfig_s3_bucket = {
      value     = aws_s3_bucket.kubeconfig_storage.bucket
      sensitive = false
    }

    # AWS region for EKS kubeconfig
    TF_VAR_aws_default_region = {
      value     = var.aws_default_region
      sensitive = false
    }

    # EKS Kubernetes version (eks cluster_type only)
    TF_VAR_eks_cluster_version = {
      value     = var.eks_cluster_version
      sensitive = false
    }

    # Optional operator IAM principal granted EKS cluster-admin (eks only)
    TF_VAR_eks_admin_principal_arn = {
      value     = var.eks_admin_principal_arn
      sensitive = false
    }

    # We pass this to the OpenTofu stack so it can be used in the inventory (k3s only)
    TF_VAR_private_key_path = {
      value     = local.private_key_full_path
      sensitive = false
    }

    # We pass this to the OpenTofu stack so it can be used in the aws ec2 instances (k3s only)
    TF_VAR_aws_private_key_name = {
      value     = local.is_k3s ? aws_key_pair.this[0].key_name : ""
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

    TF_VAR_root_volume_size = {
      value     = var.root_volume_size
      sensitive = false
    }

    TF_VAR_root_volume_type = {
      value     = var.root_volume_type
      sensitive = false
    }

    AWS_DEFAULT_REGION = {
      value     = var.aws_default_region
      sensitive = false
    }
  }

  # SSH key context only needed for k3s
  contexts = local.is_k3s ? {
    tofusible_ssh_key = spacelift_context.ssh_keys[0].id
  } : {}

  labels            = ["${local.run_tag}-opentofu"]
  project_root      = "stacks/tofu"
  repository_branch = var.repo_branch

  # Use default worker pool for OpenTofu stack if provided
  worker_pool_id = var.worker_pool_id
}

# Kick off the chain automatically once the admin stack applies.
# This triggers the OpenTofu stack, which then cascades to Ansible (via the
# dependencies reference below) and Kubernetes (via spacelift_stack_dependency),
# all auto-deploying. A new run fires only when run_tag changes (i.e. per
# deployment), so re-applying the admin stack does not re-trigger the chain.
resource "spacelift_run" "bootstrap_opentofu" {
  stack_id = module.stack_opentofu.id

  keepers = {
    run_tag = local.run_tag
  }
}

# Ansible stack is only created for k3s (installs k3s on EC2 instances)
module "stack_ansible" {
  count   = local.is_k3s ? 1 : 0
  source  = "spacelift.io/spacelift-solutions/stacks-module/spacelift"
  version = "~> 3.1"

  description     = "Stack that configures EC2 servers"
  name            = "${local.unique_prefix}TofusibleKube-Ansible"
  repository_name = "Quick-Cluster" #UPDATE_TO_YOUR_VALUE
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
    tofusible_ssh_key = spacelift_context.ssh_keys[0].id
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

  # Dependencies block for passing inventory from OpenTofu to Ansible
  dependencies = {
    TOFUSIBLE = {
      parent_stack_id = module.stack_opentofu.id

      references = {
        INVENTORY = {
          output_name    = "inventory_tofu"
          input_name     = "TOFUSIBLE_INVENTORY"
          trigger_always = true
        }
      }
    }
  }
}

# NOTE: Stack dependency is managed by the dependencies block in module.stack_ansible above
# Do not create separate spacelift_stack_dependency resources as they will conflict

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

# This bucket holds the kubeconfig, worker-pool token/private-key and the
# Prometheus-exporter API key secret, so lock it down: no public access and
# TLS-only requests.
resource "aws_s3_bucket_public_access_block" "kubeconfig_storage" {
  bucket = aws_s3_bucket.kubeconfig_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "kubeconfig_storage_tls_only" {
  bucket = aws_s3_bucket.kubeconfig_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.kubeconfig_storage.arn,
        "${aws_s3_bucket.kubeconfig_storage.arn}/*",
      ]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })

  # Ensure the public access block is applied before attaching a bucket policy.
  depends_on = [aws_s3_bucket_public_access_block.kubeconfig_storage]
}

# Output S3 bucket information
output "kubeconfig_s3_info" {
  value = {
    bucket_name      = aws_s3_bucket.kubeconfig_storage.bucket
    latest_url       = "s3://${aws_s3_bucket.kubeconfig_storage.bucket}/kubeconfig-latest.yaml"
    download_command = "aws s3 cp s3://${aws_s3_bucket.kubeconfig_storage.bucket}/kubeconfig-latest.yaml ~/home/spacelift/.kube/config"
  }
  description = "S3 bucket information for kubeconfig storage"
}



resource "spacelift_stack" "tofusible-kubernetes" {
  name        = "${local.unique_prefix}TofusibleKube-Kubernetes"
  space_id    = var.resource_space_id
  description = "Stack that deploys hello world app to K3s cluster"

  repository = "Quick-Cluster" #UPDATE_TO_YOUR_VALUE
  branch     = var.repo_branch
  # Point the KUBERNETES workflow at just the manifests dir; it recursively
  # accumulates YAML, so it must not see the vendored Helm chart (Chart.yaml has
  # no kind) or the scripts. Those are reached by the hooks via absolute path.
  project_root = "stacks/kubernetes/manifests"

  kubernetes {
    kubernetes_workflow_tool = "KUBERNETES"
  }

  runner_image = var.kubernetes_runner_image

  labels                           = ["${local.run_tag}-kubernetes"]
  enable_well_known_secret_masking = true
  allow_run_promotion              = false

  # Auto-apply so the OpenTofu -> Ansible -> Kubernetes chain completes without
  # manual confirmation once the admin stack runs (the OpenTofu/Ansible stacks
  # already set auto_deploy = true). This is the final approval gate.
  autodeploy = true

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

# Self-hosted Spacelift toggle + ACME email, consumed by deploy-selfhosted.sh.
resource "spacelift_environment_variable" "kubernetes_selfhosted_enabled" {
  stack_id = spacelift_stack.tofusible-kubernetes.id
  name     = "SELFHOSTED_ENABLED"
  value    = tostring(var.enable_selfhosted)
}

resource "spacelift_environment_variable" "kubernetes_selfhosted_acme_email" {
  stack_id = spacelift_stack.tofusible-kubernetes.id
  name     = "SELFHOSTED_ACME_EMAIL"
  value    = var.selfhosted_acme_email
}

# Context that carries the user-supplied self-hosted secrets/overrides. The admin
# stack only creates the (auto-attached) context; the operator adds a mounted file
# named "values-secrets.yaml" (license, admin/RSA/DB/MinIO secrets, domain, image
# refs) in the Spacelift UI so secrets never touch git or Terraform state.
resource "spacelift_context" "selfhosted_secrets" {
  count       = var.enable_selfhosted ? 1 : 0
  name        = "${local.unique_prefix}selfhosted-secrets"
  description = "Add a mounted file 'values-secrets.yaml' here (see stacks/kubernetes/selfhosted/values-secrets.example.yaml) to configure the self-hosted Spacelift install."
  space_id    = var.resource_space_id
  labels      = ["autoattach:${local.run_tag}-kubernetes"]
}

# k3s: Kubernetes depends on Ansible (which installs k3s and uploads kubeconfig)
resource "spacelift_stack_dependency" "kubernetes_depends_on_ansible" {
  count               = local.is_k3s ? 1 : 0
  stack_id            = spacelift_stack.tofusible-kubernetes.id
  depends_on_stack_id = module.stack_ansible[0].id
}

# EKS: Kubernetes depends directly on OpenTofu (which creates EKS and uploads kubeconfig)
resource "spacelift_stack_dependency" "kubernetes_depends_on_opentofu" {
  count               = local.is_eks ? 1 : 0
  stack_id            = spacelift_stack.tofusible-kubernetes.id
  depends_on_stack_id = module.stack_opentofu.id
}

# Define a reusable Context that downloads your kubeconfig from S3
# and optionally deploys Spacelift private workers after apply
resource "spacelift_context" "kubeconfig_hooks" {
  name        = "${local.unique_prefix}kubeconfig-hooks"
  description = "Downloads the K3s kubeconfig and optionally deploys Spacelift workers"

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

  # Runs after terraform apply / kubernetes apply
  # Deploys the Spacelift private worker pool (and KEDA autoscaling when enabled).
  # The heavy lifting lives in a checked-in, testable script; this hook just
  # points KUBECONFIG at the downloaded config and runs it. The script no-ops
  # when no worker pool was configured for this deployment.
  after_apply = [
    # Karpenter first (EKS only; no-ops on k3s) so node capacity is elastic before
    # the worker/monitoring workloads below need scheduling.
    "KUBECONFIG=/mnt/workspace/.kube/config bash /mnt/workspace/source/stacks/kubernetes/scripts/deploy-karpenter.sh",
    "KUBECONFIG=/mnt/workspace/.kube/config bash /mnt/workspace/source/stacks/kubernetes/scripts/deploy-workers-keda.sh",
    # Optional full self-hosted Spacelift install (no-ops unless SELFHOSTED_ENABLED=true).
    "KUBECONFIG=/mnt/workspace/.kube/config bash /mnt/workspace/source/stacks/kubernetes/scripts/deploy-selfhosted.sh",
  ]
}

# Attach that Context to your Kubernetes stack
resource "spacelift_context_attachment" "tofusible_k8s_hooks" {
  context_id = spacelift_context.kubeconfig_hooks.id
  stack_id   = spacelift_stack.tofusible-kubernetes.id
}