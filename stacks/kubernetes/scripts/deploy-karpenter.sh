#!/usr/bin/env bash
#
# deploy-karpenter.sh
#
# Installs Karpenter into the EKS cluster and applies a default EC2NodeClass +
# NodePool so the cluster scales nodes elastically. Also creates a default gp3
# StorageClass (backed by the EBS CSI driver) for dynamic PersistentVolumes.
#
# Driven by the karpenter/config.json object the OpenTofu stack publishes to S3.
# It no-ops on k3s clusters (no config object present).
#
# Required environment:
#   KUBECONFIG            - path to the cluster kubeconfig (set by the hook)
#   KUBECONFIG_S3_BUCKET  - S3 bucket holding karpenter/config.json

set -euo pipefail

WORK_DIR="${KARPENTER_DIR:-/tmp/karpenter}"
log() { echo "$@"; }

# ── 1) Bail out cleanly when there is no Karpenter config (i.e. not EKS) ───────
if ! aws s3 ls "s3://${KUBECONFIG_S3_BUCKET}/karpenter/config.json" >/dev/null 2>&1; then
  log "ℹ️  No Karpenter config in S3 (non-EKS cluster); skipping Karpenter setup."
  exit 0
fi

mkdir -p "$WORK_DIR"
aws s3 cp "s3://${KUBECONFIG_S3_BUCKET}/karpenter/config.json" "${WORK_DIR}/config.json" --quiet

read_cfg() { python3 -c "import json;print(json.load(open('${WORK_DIR}/config.json')).get('$1',''))"; }

CLUSTER_NAME="$(read_cfg cluster_name)"
CLUSTER_ENDPOINT="$(read_cfg cluster_endpoint)"
KARPENTER_VERSION="$(read_cfg karpenter_version)"
QUEUE_NAME="$(read_cfg queue_name)"

log "🪴 Configuring Karpenter ${KARPENTER_VERSION} for cluster ${CLUSTER_NAME}"

# ── 2) Default gp3 StorageClass (EBS CSI) ──────────────────────────────────────
# WaitForFirstConsumer so volumes are created in the AZ where the pod is scheduled
# (important with Karpenter, which can place nodes in any AZ).
log "💾 Applying default gp3 StorageClass..."
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
EOF
# Drop the default flag from gp2 if it exists, so gp3 is the sole default.
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class- --overwrite >/dev/null 2>&1 || true

# ── 3) Install Karpenter (Helm, from public ECR) ───────────────────────────────
# Public ECR usually allows anonymous pulls; attempt a login but don't fail if
# the runner role can't mint a public-ECR token.
aws ecr-public get-login-password --region us-east-1 2>/dev/null \
  | helm registry login --username AWS --password-stdin public.ecr.aws >/dev/null 2>&1 || true

log "⚡ Installing Karpenter via Helm..."
helm upgrade --install karpenter "oci://public.ecr.aws/karpenter/karpenter" \
  --version "$KARPENTER_VERSION" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${QUEUE_NAME}" \
  --wait --timeout 10m

# ── 4) Wait for Karpenter CRDs ─────────────────────────────────────────────────
log "⏳ Waiting for Karpenter CRDs..."
kubectl wait --for=condition=Established \
  crd/ec2nodeclasses.karpenter.k8s.aws \
  crd/nodepools.karpenter.sh \
  --timeout=180s

# ── 5) Default EC2NodeClass + NodePool ─────────────────────────────────────────
# Render from config (subnets/SG selected by ID, AMI via the al2023 alias).
log "🚀 Applying default EC2NodeClass + NodePool..."
python3 - "${WORK_DIR}/config.json" <<'PY' | kubectl apply -f -
import json, sys
cfg = json.load(open(sys.argv[1]))
role = cfg["node_iam_role_name"]
sg = cfg["node_security_group_id"]
subnets = cfg["subnet_ids"]
subnet_terms = "\n".join(f"    - id: {s}" for s in subnets)
print(f"""apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: {role}
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
{subnet_terms}
  securityGroupSelectorTerms:
    - id: {sg}
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required
    httpPutResponseHopLimit: 1
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["4"]
  limits:
    cpu: "100"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
""")
PY

log "✅ Karpenter ready. Verifying..."
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl get nodepool,ec2nodeclass

rm -rf "$WORK_DIR"
log "🎉 Karpenter will provision nodes on demand for unschedulable pods."
