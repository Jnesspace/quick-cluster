terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    spacelift = {
      source = "spacelift-io/spacelift"
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

  environment_variables = {
    # !IMPORTANT
    # This variable tells ansible where to find the inventory file
    ANSIBLE_INVENTORY = {
      value     = "tofusible.yml"
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

resource "spacelift_stack" "kubernetes" {
  name     = "Tofusible - Kubernetes"
  space_id = var.resource_space_id

  repository = "Quick-Cluster"
  branch     = "main"

  project_root = "stacks/kubernetes"

  kubernetes {
    kubectl_version = "1.33.2"
  }

  labels = ["tofusible", "kubernetes"]

  autodeploy = true
  enable_well_known_secret_masking = true
  github_action_deploy = false
}

resource "spacelift_stack_dependency" "kubernetes_depends_on_ansible" {
  stack_id            = spacelift_stack.kubernetes.id
  depends_on_stack_id = module.stack_ansible.id
}

resource "spacelift_stack_dependency_reference" "kubernetes_kubeconfig" {
  stack_dependency_id = spacelift_stack_dependency.kubernetes_depends_on_ansible.id
  output_name         = "kubeconfig_content"
  input_name          = "KUBE_CONFIG_FILE_CONTENT"
  trigger_always      = true
}