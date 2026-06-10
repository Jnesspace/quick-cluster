#!/usr/bin/env bash
#
# deploy-selfhosted-workers.sh
#
# Deploys auto-registering Spacelift workers for the in-cluster self-hosted
# instance. Uses the spacelift-workerpool-controller's AUTO-REGISTRATION feature:
# given a spacelift-api-credentials secret + a tokenless WorkerPool CR, the
# controller creates and manages the worker pool in Spacelift for you — no manual
# UI pool, no CSR, no token download. Workers run in-cluster and reach the
# self-hosted server + MQTT over in-cluster service DNS.
#
# Gated by SELFHOSTED_WORKERS_ENABLED=true and a config in AWS SSM
# (default /spacelift-selfhosted/workers, a JSON SecureString):
#   {
#     "keyId":        "<self-hosted API key id>",
#     "keySecret":    "<self-hosted API key secret>",
#     "endpoint":     "http://spacelift-server.spacelift.svc.cluster.local",
#     "poolName":     "selfhosted-workers",
#     "poolSize":     2,
#     "launcherImage":"<acct>.dkr.ecr.<region>.amazonaws.com/spacelift-launcher:v5.1.2"
#   }
# The API key needs the "Worker pool controller" role in the target space.
#
# Required env: KUBECONFIG, KUBECONFIG_S3_BUCKET (present on the stack)

set -euo pipefail

NS="spacelift-workers"
SSM_PARAM="${SELFHOSTED_WORKERS_SSM:-/spacelift-selfhosted/workers}"
log() { echo "$@"; }

if [ "${SELFHOSTED_WORKERS_ENABLED:-false}" != "true" ]; then
  log "ℹ️  SELFHOSTED_WORKERS_ENABLED is not 'true'; skipping self-hosted workers."
  exit 0
fi

# ── Pull worker config from SSM ────────────────────────────────────────────────
CFG="$(aws ssm get-parameter --name "$SSM_PARAM" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
if [ -z "$CFG" ] || [ "$CFG" = "None" ]; then
  log "⚠️  Self-hosted workers enabled but SSM param ${SSM_PARAM} is missing."
  log "    Create a Spacelift API key in the self-hosted UI with the 'Worker pool"
  log "    controller' role, then store a JSON config there (keyId, keySecret,"
  log "    endpoint, poolName, poolSize, launcherImage). Skipping for now."
  exit 0
fi

read_cfg() { printf '%s' "$CFG" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }
KEY_ID="$(read_cfg keyId)"
KEY_SECRET="$(read_cfg keySecret)"
ENDPOINT="$(read_cfg endpoint)"; [ -n "$ENDPOINT" ] || ENDPOINT="http://spacelift-server.spacelift.svc.cluster.local"
POOL_NAME="$(read_cfg poolName)"; [ -n "$POOL_NAME" ] || POOL_NAME="selfhosted-workers"
POOL_SIZE="$(read_cfg poolSize)"; [ -n "$POOL_SIZE" ] || POOL_SIZE="2"
LAUNCHER_IMAGE="$(read_cfg launcherImage)"

if [ -z "$KEY_ID" ] || [ -z "$KEY_SECRET" ] || [ -z "$LAUNCHER_IMAGE" ]; then
  log "❌ SSM config is missing keyId/keySecret/launcherImage. Aborting workers." >&2
  exit 1
fi

log "👷 Auto-registering self-hosted workers: pool=${POOL_NAME} size=${POOL_SIZE} endpoint=${ENDPOINT}"

# ── Controller (upstream) ──────────────────────────────────────────────────────
helm repo add spacelift https://downloads.spacelift.io/helm >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

log "📦 Installing spacelift-workerpool-controller into ${NS}..."
helm upgrade --install spacelift-worker-controller spacelift/spacelift-workerpool-controller \
  --namespace "$NS" --wait --timeout 5m

# ── Auto-registration credentials (must live in the controller's namespace) ────
log "🔐 Creating spacelift-api-credentials secret..."
kubectl create secret generic spacelift-api-credentials \
  --namespace="$NS" \
  --from-literal=keyId="$KEY_ID" \
  --from-literal=keySecret="$KEY_SECRET" \
  --from-literal=endpoint="$ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Tokenless WorkerPool CR -> controller auto-registers it in Spacelift ───────
log "⏳ Waiting for the WorkerPool CRD..."
kubectl wait --for=condition=Established crd/workerpools.workers.spacelift.io --timeout=180s

log "🚀 Applying tokenless WorkerPool (triggers auto-registration)..."
kubectl apply -f - <<EOF
apiVersion: workers.spacelift.io/v1beta1
kind: WorkerPool
metadata:
  name: ${POOL_NAME}
  namespace: ${NS}
spec:
  poolSize: ${POOL_SIZE}
  pod:
    launcherImage: ${LAUNCHER_IMAGE}
EOF

log "✅ Workers deployed. Verifying..."
kubectl -n "$NS" get workerpools,pods
log "🎉 The controller registers '${POOL_NAME}' in self-hosted Spacelift; launcher pods connect over in-cluster MQTT."
