# SSH key generation removed - users must provide their own existing AWS key pair
# via the ssh_key_name variable. This avoids ownership and mounting issues.
#
# To use this setup:
# 1. Create an SSH key pair in AWS Console or CLI
# 2. Keep the private key file locally for manual SSH access if needed
# 3. Provide the key name when creating the blueprint

# resource "tls_private_key" "this" {
#   algorithm = "RSA"
#   rsa_bits  = 4096
# }

# resource "aws_key_pair" "this" {
#   key_name   = "ssh_example_tofu_ansible-${random_id.bucket_suffix.hex}"
#   public_key = tls_private_key.this.public_key_openssh
# }

# resource "spacelift_context" "ssh_keys" {
#   name = "${local.unique_tag}ssh-key"

#   space_id = var.resource_space_id

#   labels = ["autoattach:${local.run_tag}-ansible"]
# }

# resource "spacelift_mounted_file" "ssh_private_key" {
#   context_id    = spacelift_context.ssh_keys.id
#   content       = base64encode(tls_private_key.this.private_key_pem)
#   relative_path = "spacelift.pem"
# }

# locals {
#   private_key_full_path = "/mnt/workspace/${spacelift_mounted_file.ssh_private_key.relative_path}"
# }