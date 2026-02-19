# SSH keys are only needed for k3s (Ansible SSH access to EC2 instances)
resource "tls_private_key" "this" {
  count     = local.is_k3s ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  count      = local.is_k3s ? 1 : 0
  key_name   = "ssh_example_tofu_ansible-${random_id.bucket_suffix.hex}"
  public_key = tls_private_key.this[0].public_key_openssh
}

resource "spacelift_context" "ssh_keys" {
  count    = local.is_k3s ? 1 : 0
  name     = "${local.unique_tag}ssh-key"
  space_id = var.resource_space_id
  labels   = ["autoattach:${local.run_tag}-ansible"]
}

resource "spacelift_mounted_file" "ssh_private_key" {
  count         = local.is_k3s ? 1 : 0
  context_id    = spacelift_context.ssh_keys[0].id
  content       = base64encode(tls_private_key.this[0].private_key_pem)
  relative_path = "spacelift.pem"
}

locals {
  # Path is only valid for k3s, but we provide a default for EKS to avoid errors
  private_key_full_path = local.is_k3s ? "/mnt/workspace/${spacelift_mounted_file.ssh_private_key[0].relative_path}" : ""
}