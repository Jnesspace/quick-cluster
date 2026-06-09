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
  worker_pool_name = "${local.run_tag_k8s}-workers"

  # KEDA autoscaling is only meaningful when we are actually deploying a pool.
  enable_autoscaling = local.deploy_workers && var.enable_worker_autoscaling

  # Prometheus exporter (promex) endpoint: explicit override, else derive from the
  # current Spacelift account name (SaaS pattern: https://<account>.app.spacelift.io).
  spacelift_api_endpoint = var.spacelift_api_endpoint != "" ? var.spacelift_api_endpoint : "https://${data.spacelift_account.this.name}.app.spacelift.io"
}

# Current account, used to derive the exporter API endpoint when not supplied.
data "spacelift_account" "this" {}

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
# Step 3b: Prometheus-exporter API key (autoscaling only)
#
# The Spacelift Prometheus exporter (spacelift-promex) authenticates to the
# Spacelift API to publish the spacelift_worker_pool_runs_pending metric that
# KEDA scales on. We create a dedicated API key and grant it read access to the
# space that holds the worker pool. The secret is handed to the Kubernetes stack
# via the (locked-down) S3 bucket below.
#──────────────────────────────────────────────────────────────────────────────
resource "spacelift_api_key" "promex" {
  count = local.enable_autoscaling ? 1 : 0
  name  = "${local.worker_pool_name}-promex"
}

# The exporter needs an admin key (some metric fields require admin access), so
# attach the key to the built-in "space-admin" system role within the resource
# space rather than minting a per-deployment role.
# NOTE: reading system roles / attaching them requires the admin stack to have
# admin access to the root Space.
data "spacelift_role" "space_admin" {
  count = local.enable_autoscaling ? 1 : 0
  slug  = "space-admin"
}

resource "spacelift_role_attachment" "promex" {
  count      = local.enable_autoscaling ? 1 : 0
  api_key_id = spacelift_api_key.promex[0].id
  role_id    = data.spacelift_role.space_admin[0].id
  space_id   = var.resource_space_id
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

    # KEDA autoscaling settings consumed by deploy-workers-keda.sh
    autoscaling_enabled = local.enable_autoscaling
    min_workers         = var.min_workers
    max_workers         = var.max_workers
    api_key_id          = local.enable_autoscaling ? spacelift_api_key.promex[0].id : ""
    api_endpoint        = local.enable_autoscaling ? local.spacelift_api_endpoint : ""
  })

  server_side_encryption = "AES256"
}

# Prometheus-exporter API key secret (autoscaling only). Stored encrypted; the
# Kubernetes stack loads it into the spacelift-promex credentials secret.
resource "aws_s3_object" "worker_pool_api_key_secret" {
  count   = local.enable_autoscaling ? 1 : 0
  bucket  = aws_s3_bucket.kubeconfig_storage.bucket
  key     = "worker-pool/api-key-secret"
  content = spacelift_api_key.promex[0].secret

  server_side_encryption = "AES256"
}

#──────────────────────────────────────────────────────────────────────────────
# Outputs
#──────────────────────────────────────────────────────────────────────────────
output "worker_pool_info" {
  value = local.deploy_workers ? {
    enabled             = true
    pool_id             = spacelift_worker_pool.this[0].id
    pool_name           = local.worker_pool_name
    pool_size           = local.worker_pool_size
    autoscaling_enabled = local.enable_autoscaling
    min_workers         = local.enable_autoscaling ? var.min_workers : null
    max_workers         = local.enable_autoscaling ? var.max_workers : null
    } : {
    enabled             = false
    pool_id             = null
    pool_name           = null
    pool_size           = 0
    autoscaling_enabled = false
    min_workers         = null
    max_workers         = null
  }
  description = "Worker pool information for reference"
}
