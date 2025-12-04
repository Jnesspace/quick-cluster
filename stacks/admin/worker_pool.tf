#──────────────────────────────────────────────────────────────────────────────
# Private Worker Pool Auto-Provisioning
#
# When deploy_private_workers > 0, this creates:
# 1. A TLS private key (ECDSA P384)
# 2. A Certificate Signing Request (CSR) from that key
# 3. A Spacelift worker pool registered with that CSR
# 4. S3 objects containing the credentials for K8s deployment
#
# The Kubernetes stack then picks up these credentials and deploys
# the Spacelift worker controller via Helm.
#──────────────────────────────────────────────────────────────────────────────

locals {
  deploy_workers   = tonumber(var.deploy_private_workers) > 0
  worker_pool_size = tonumber(var.deploy_private_workers)
  worker_pool_name = "${local.run_tag}-workers"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 1: Generate private key (only if deploying workers)
#
# We use ECDSA P384 which provides strong security with smaller key sizes
# than RSA, resulting in faster operations.
#──────────────────────────────────────────────────────────────────────────────
resource "tls_private_key" "worker_pool" {
  count       = local.deploy_workers ? 1 : 0
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 2: Generate CSR from the private key
#
# The CSR contains our public key and identity information. We send this to
# Spacelift, which validates it and returns a token. The private key never
# leaves our infrastructure.
#──────────────────────────────────────────────────────────────────────────────
resource "tls_cert_request" "worker_pool" {
  count           = local.deploy_workers ? 1 : 0
  private_key_pem = tls_private_key.worker_pool[0].private_key_pem

  subject {
    common_name  = local.worker_pool_name
    organization = "Spacelift Workers"
  }
}

#──────────────────────────────────────────────────────────────────────────────
# Step 3: Create Spacelift worker pool with CSR
#
# Spacelift validates our CSR and returns credentials (config/token) that
# workers use to authenticate. The pool is created in the same space as
# all other resources.
#──────────────────────────────────────────────────────────────────────────────
resource "spacelift_worker_pool" "this" {
  count       = local.deploy_workers ? 1 : 0
  name        = local.worker_pool_name
  description = "Auto-provisioned workers for ${local.run_tag} K3s cluster"

  # Same space as all other resources
  space_id = var.resource_space_id

  # CSR must be base64 encoded
  csr = base64encode(tls_cert_request.worker_pool[0].cert_request_pem)

  labels = [local.run_tag, "auto-provisioned", "k3s"]
}

#──────────────────────────────────────────────────────────────────────────────
# Step 4: Store credentials in S3 for Kubernetes stack to consume
#
# We store three objects:
# - token: The Spacelift-issued authentication token
# - private-key: Our generated private key (base64 for K8s secret)
# - config.json: Metadata about the pool (name, size, etc.)
#──────────────────────────────────────────────────────────────────────────────
resource "aws_s3_object" "worker_pool_token" {
  count   = local.deploy_workers ? 1 : 0
  bucket  = aws_s3_bucket.kubeconfig_storage.bucket
  key     = "worker-pool/token"
  content = spacelift_worker_pool.this[0].config

  server_side_encryption = "AES256"
}

resource "aws_s3_object" "worker_pool_private_key" {
  count  = local.deploy_workers ? 1 : 0
  bucket = aws_s3_bucket.kubeconfig_storage.bucket
  key    = "worker-pool/private-key"

  # Base64 encode for direct use in K8s secret
  content = base64encode(tls_private_key.worker_pool[0].private_key_pem)

  server_side_encryption = "AES256"
}

resource "aws_s3_object" "worker_pool_config" {
  count  = local.deploy_workers ? 1 : 0
  bucket = aws_s3_bucket.kubeconfig_storage.bucket
  key    = "worker-pool/config.json"

  content = jsonencode({
    pool_name = local.worker_pool_name
    pool_id   = spacelift_worker_pool.this[0].id
    pool_size = local.worker_pool_size
    namespace = "spacelift-worker-controller-system"
  })

  server_side_encryption = "AES256"
}

#──────────────────────────────────────────────────────────────────────────────
# Outputs
#──────────────────────────────────────────────────────────────────────────────
output "worker_pool_info" {
  value = local.deploy_workers ? {
    enabled   = true
    pool_id   = spacelift_worker_pool.this[0].id
    pool_name = local.worker_pool_name
    pool_size = local.worker_pool_size
  } : {
    enabled   = false
    pool_id   = null
    pool_name = null
    pool_size = 0
  }
  description = "Worker pool information for reference"
}
