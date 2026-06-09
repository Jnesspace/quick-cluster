#!/usr/bin/env bash
#
# deploy-workers-keda.sh
#
# Deploys the Spacelift private worker pool into the cluster and, when
# autoscaling is enabled, wires up KEDA queue-based autoscaling:
#
#   spacelift-workerpool-controller (+ spacelift-promex exporter)
#     -> kube-prometheus-stack          (scrapes the exporter via a PodMonitor)
#       -> KEDA ScaledObject            (scales the WorkerPool CRD on queue depth)
#
# It is driven entirely by the worker-pool credentials/config the admin stack
# writes to S3 (worker-pool/{token,private-key,config.json,api-key-secret}).
#
# Required environment:
#   KUBECONFIG            - path to the cluster kubeconfig (set by the hook)
#   KUBECONFIG_S3_BUCKET  - S3 bucket holding the worker-pool credentials
#
# This script is idempotent: every apply re-converges the helm releases and
# Kubernetes resources to the desired state.

set -euo pipefail

WORK_DIR="${WORKER_POOL_DIR:-/tmp/worker-pool}"
CONTROLLER_NS="spacelift-worker-controller-system"
CONTROLLER_RELEASE="spacelift-worker-controller"
PROM_NS="kube-prom-stack"
PROM_RELEASE="kube-prom-stack"
KEDA_NS="keda"
PROMEX_SECRET_NAME="spacelift-prometheus-exporter-credentials"

log() { echo "$@"; }

# ── 1) Bail out cleanly when no worker pool was configured for this deployment ──
if ! aws s3 ls "s3://${KUBECONFIG_S3_BUCKET}/worker-pool/config.json" >/dev/null 2>&1; then
  log "ℹ️  No worker-pool configuration found in S3; skipping worker deployment."
  exit 0
fi

# ── 2) Pull credentials + config ──────────────────────────────────────────────
mkdir -p "$WORK_DIR"
aws s3 cp "s3://${KUBECONFIG_S3_BUCKET}/worker-pool/token"       "${WORK_DIR}/token"       --quiet
aws s3 cp "s3://${KUBECONFIG_S3_BUCKET}/worker-pool/private-key" "${WORK_DIR}/privateKey"  --quiet
aws s3 cp "s3://${KUBECONFIG_S3_BUCKET}/worker-pool/config.json" "${WORK_DIR}/config.json" --quiet

# python3 is available on Spacelift workers; use it to read config.json safely.
read_cfg() { python3 -c "import json;print(json.load(open('${WORK_DIR}/config.json')).get('$1',''))"; }

POOL_NAME="$(read_cfg pool_name)"
POOL_SIZE="$(read_cfg pool_size)"
MIN_WORKERS="$(read_cfg min_workers)"
MAX_WORKERS="$(read_cfg max_workers)"
API_KEY_ID="$(read_cfg api_key_id)"
API_ENDPOINT="$(read_cfg api_endpoint)"
# python prints booleans as True/False; normalise to lower case.
AUTOSCALING="$(read_cfg autoscaling_enabled | tr '[:upper:]' '[:lower:]')"

log "📦 Worker pool: ${POOL_NAME} (autoscaling=${AUTOSCALING}, min=${MIN_WORKERS}, max=${MAX_WORKERS}, static_size=${POOL_SIZE})"

helm repo add spacelift https://downloads.spacelift.io/helm >/dev/null 2>&1 || true

# ── 3) Worker pool controller (+ promex exporter when autoscaling) ─────────────
kubectl create namespace "$CONTROLLER_NS" --dry-run=client -o yaml | kubectl apply -f -

CONTROLLER_ARGS=(
  "$CONTROLLER_RELEASE" spacelift/spacelift-workerpool-controller
  --install
  --namespace "$CONTROLLER_NS"
  --wait --timeout 5m
)

if [ "$AUTOSCALING" = "true" ]; then
  aws s3 cp "s3://${KUBECONFIG_S3_BUCKET}/worker-pool/api-key-secret" "${WORK_DIR}/api-key-secret" --quiet

  log "🔐 Creating Prometheus-exporter credentials secret (${PROMEX_SECRET_NAME})..."
  kubectl create secret generic "$PROMEX_SECRET_NAME" \
    --namespace="$CONTROLLER_NS" \
    --from-file=SPACELIFT_PROMEX_API_KEY_SECRET="${WORK_DIR}/api-key-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

  CONTROLLER_ARGS+=(
    --set spacelift-promex.enabled=true
    --set spacelift-promex.apiEndpoint="$API_ENDPOINT"
    --set spacelift-promex.apiKeyId="$API_KEY_ID"
    --set spacelift-promex.apiKeySecretName="$PROMEX_SECRET_NAME"
  )
fi

helm repo update >/dev/null
log "📦 Installing Spacelift worker pool controller..."
helm upgrade "${CONTROLLER_ARGS[@]}"

# ── 4) Wait for the WorkerPool CRD to be established ───────────────────────────
log "⏳ Waiting for the WorkerPool CRD..."
kubectl wait --for=condition=Established crd/workerpools.workers.spacelift.io --timeout=180s

# ── 5) Worker pool authentication secret ───────────────────────────────────────
log "🔐 Creating worker pool secret (${POOL_NAME})..."
kubectl create secret generic "$POOL_NAME" \
  --namespace="$CONTROLLER_NS" \
  --from-file=token="${WORK_DIR}/token" \
  --from-file=privateKey="${WORK_DIR}/privateKey" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 6) WorkerPool resource ─────────────────────────────────────────────────────
# With autoscaling, start at min_workers — KEDA then owns the replica count via
# the WorkerPool /scale subresource. Otherwise use the static pool size.
if [ "$AUTOSCALING" = "true" ]; then
  INITIAL_SIZE="$MIN_WORKERS"
else
  INITIAL_SIZE="$POOL_SIZE"
fi

log "🚀 Applying WorkerPool resource (poolSize=${INITIAL_SIZE})..."
kubectl apply -f - <<EOF
apiVersion: workers.spacelift.io/v1beta1
kind: WorkerPool
metadata:
  name: ${POOL_NAME}
  namespace: ${CONTROLLER_NS}
spec:
  poolSize: ${INITIAL_SIZE}
  token:
    secretKeyRef:
      name: ${POOL_NAME}
      key: token
  privateKey:
    secretKeyRef:
      name: ${POOL_NAME}
      key: privateKey
EOF

if [ "$AUTOSCALING" != "true" ]; then
  log "✅ Static worker pool deployed (poolSize=${POOL_SIZE}); autoscaling disabled."
  kubectl -n "$CONTROLLER_NS" get workerpools
  rm -rf "$WORK_DIR"
  exit 0
fi

# ── 7) Autoscaling stack: kube-prometheus-stack + KEDA ─────────────────────────
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "📊 Installing kube-prometheus-stack..."
helm upgrade "$PROM_RELEASE" prometheus-community/kube-prometheus-stack \
  --install --namespace "$PROM_NS" --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m

log "⚡ Installing KEDA..."
helm upgrade keda kedacore/keda \
  --install --namespace "$KEDA_NS" --create-namespace \
  --wait --timeout 5m

# PodMonitor so Prometheus scrapes the spacelift-promex exporter pod.
log "🔎 Applying PodMonitor for the Spacelift exporter..."
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: spacelift-promex
  namespace: ${CONTROLLER_NS}
  labels:
    release: ${PROM_RELEASE}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: spacelift-promex
  namespaceSelector:
    matchNames:
      - ${CONTROLLER_NS}
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
EOF

# KEDA ScaledObject scales the WorkerPool CRD on pending-run queue depth.
# serverAddress uses the operator's stable "prometheus-operated" service.
log "🤖 Applying KEDA ScaledObject (min=${MIN_WORKERS}, max=${MAX_WORKERS})..."
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${POOL_NAME}-autoscaler
  namespace: ${CONTROLLER_NS}
spec:
  scaleTargetRef:
    apiVersion: workers.spacelift.io/v1beta1
    kind: WorkerPool
    name: ${POOL_NAME}
  pollingInterval: 30
  cooldownPeriod: 300
  minReplicaCount: ${MIN_WORKERS}
  maxReplicaCount: ${MAX_WORKERS}
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-operated.${PROM_NS}.svc.cluster.local:9090
        query: max_over_time(spacelift_worker_pool_runs_pending{worker_pool_name='${POOL_NAME}'}[5m])
        threshold: '1'
        activationThreshold: '0'
EOF

log "✅ Autoscaling worker pool deployed. Verifying..."
kubectl -n "$CONTROLLER_NS" get workerpools,scaledobject,podmonitor
kubectl -n "$CONTROLLER_NS" get pods

rm -rf "$WORK_DIR"
log "🎉 KEDA will scale ${POOL_NAME} between ${MIN_WORKERS} and ${MAX_WORKERS} based on Spacelift queue depth."
