#!/usr/bin/env bash
#
# deploy-selfhosted.sh
#
# Optional: installs a full self-hosted Spacelift instance from the vendored
# umbrella chart (stacks/kubernetes/selfhosted/) — the Spacelift app (server /
# drain / scheduler / MQTT) plus in-cluster MinIO (object storage) and Postgres.
#
# Secrets ("external secrets", pulled securely at run time): the values overrides
# (license, RSA key, passwords, image refs, hostnames) come from EITHER a mounted
# values-secrets.yaml OR — preferred — an AWS SSM SecureString parameter that the
# Spacelift run reads via the stack's AWS integration. SSM persists across
# teardown and keeps secrets out of git and Terraform state.
#
# Access modes:
#   * No-DNS / port-forward (default): nothing public; reach the UI with
#     `kubectl -n spacelift port-forward svc/spacelift 8080:80`.
#   * Domain mode (SELFHOSTED_ACME_EMAIL set): also installs ingress-nginx +
#     cert-manager + a Let's Encrypt ClusterIssuer.
#
# Required environment:
#   KUBECONFIG               - cluster kubeconfig (set by the hook)
# Optional environment:
#   SELFHOSTED_ENABLED       - "true" to run (anything else = no-op)
#   SELFHOSTED_ACME_EMAIL    - set => domain mode (ingress-nginx + cert-manager)
#   SELFHOSTED_SSM_SECRETS   - SSM param holding the whole values-secrets.yaml
#                              (default /spacelift-selfhosted/values-secrets)

set -euo pipefail

CHART_DIR="/mnt/workspace/source/stacks/kubernetes/selfhosted"
MOUNTED_SECRETS="/mnt/workspace/values-secrets.yaml"
SSM_SECRETS_PARAM="${SELFHOSTED_SSM_SECRETS:-/spacelift-selfhosted/values-secrets}"
NAMESPACE="spacelift"
log() { echo "$@"; }

# ── 1) Toggle gate ─────────────────────────────────────────────────────────────
if [ "${SELFHOSTED_ENABLED:-false}" != "true" ]; then
  log "ℹ️  SELFHOSTED_ENABLED is not 'true'; skipping self-hosted Spacelift install."
  exit 0
fi

# ── 2) Resolve the secrets/values override (mounted file, else SSM at runtime) ─
VALUES_FILE=""
if [ -f "$MOUNTED_SECRETS" ]; then
  VALUES_FILE="$MOUNTED_SECRETS"
  log "🔐 Using mounted values-secrets.yaml."
else
  TMP_VALUES="$(mktemp)"
  trap 'rm -f "$TMP_VALUES"' EXIT
  if aws ssm get-parameter --name "$SSM_SECRETS_PARAM" --with-decryption \
        --query Parameter.Value --output text > "$TMP_VALUES" 2>/dev/null \
     && [ -s "$TMP_VALUES" ] && [ "$(head -c4 "$TMP_VALUES")" != "None" ]; then
    VALUES_FILE="$TMP_VALUES"
    log "🔐 Pulled secrets from SSM (${SSM_SECRETS_PARAM}) at run time."
  fi
fi

if [ -z "$VALUES_FILE" ]; then
  log "⚠️  Self-hosted enabled but no secrets found."
  log "    Provide them one of two ways:"
  log "      A) AWS SSM (recommended): put your filled values-secrets.yaml into"
  log "         the SecureString param '${SSM_SECRETS_PARAM}' (see"
  log "         stacks/kubernetes/scripts/README or the runbook)."
  log "      B) Mount a file 'values-secrets.yaml' on the '<prefix>selfhosted-secrets' context."
  log "    Skipping for now."
  exit 0
fi

# ── 3) Ingress mode (only when a domain/ACME email is provided) ────────────────
INGRESS_ARGS=()
if [ -n "${SELFHOSTED_ACME_EMAIL:-}" ]; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  log "🌐 Installing ingress-nginx..."
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.config.enable-underscores-in-headers="true" \
    --wait --timeout 10m

  log "🔏 Installing cert-manager + Let's Encrypt ClusterIssuer (${SELFHOSTED_ACME_EMAIL})..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 10m
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${SELFHOSTED_ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
else
  log "🔌 No-DNS mode: ingress disabled (reach the app via kubectl port-forward)."
  INGRESS_ARGS=(--set spacelift.ingress.enabled=false --set minio.ingress.enabled=false)
fi

# ── 4) Durable gp3 PVCs when available (EKS) ───────────────────────────────────
STORAGE_ARGS=()
if kubectl get storageclass gp3 >/dev/null 2>&1; then
  STORAGE_ARGS+=(--set minio.persistence.storageClass=gp3 --set postgres.persistence.storageClass=gp3)
  log "💾 Using gp3 StorageClass for MinIO/Postgres PVCs."
fi

# ── 5) Install the umbrella chart ──────────────────────────────────────────────
# --skip-schema-validation is required: the upstream chart's strict schema rejects
# the 'global' key Helm injects when it runs as a subchart.
log "🚀 Installing self-hosted Spacelift (helm upgrade --install)..."
helm upgrade --install spacelift "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  "${INGRESS_ARGS[@]}" \
  "${STORAGE_ARGS[@]}" \
  --skip-schema-validation \
  --wait --timeout 15m

log "✅ Self-hosted Spacelift deployed. Pods:"
kubectl -n "$NAMESPACE" get pods
if [ -n "${SELFHOSTED_ACME_EMAIL:-}" ]; then
  echo "🌐 Domain mode — point DNS at the ingress-nginx load balancer:"
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide || true
else
  echo "🔌 No-DNS mode. Access the UI from your machine with:"
  echo "    kubectl -n ${NAMESPACE} port-forward svc/spacelift 8080:80"
  echo "    kubectl -n ${NAMESPACE} port-forward svc/minio 9000:9000   # for object up/downloads"
  echo "    then open http://localhost:8080"
fi
