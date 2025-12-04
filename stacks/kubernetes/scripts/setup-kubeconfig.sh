#!/bin/bash
set -e

echo "🔧 Setting up kubeconfig for Kubernetes deployment..."

# Check if S3 bucket is provided
if [ -z "$KUBECONFIG_S3_BUCKET" ]; then
    echo "❌ Error: KUBECONFIG_S3_BUCKET environment variable not set"
    exit 1
fi

# Use absolute path for .kube directory
KUBE_DIR="/home/spacelift/.kube"
KUBECONFIG_FILE="$KUBE_DIR/config"

# Create .kube directory with absolute path
mkdir -p "$KUBE_DIR"

# Download kubeconfig from S3 to absolute path
echo "📥 Downloading kubeconfig from S3..."
aws s3 cp s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml "$KUBECONFIG_FILE"

# Set proper permissions
chmod 600 "$KUBECONFIG_FILE"

# Debug: Show what we downloaded
echo "🔍 Contents of downloaded kubeconfig:"
echo "======================================"
cat "$KUBECONFIG_FILE"
echo "======================================="

# Debug: Check server URL specifically
echo "🔍 Server URL in kubeconfig:"
grep "server:" "$KUBECONFIG_FILE" || echo "No server URL found!"

# Export KUBECONFIG explicitly with absolute path
export KUBECONFIG="$KUBECONFIG_FILE"
echo "🔧 KUBECONFIG set to: $KUBECONFIG"

# Debug: Show current kubectl config
echo "🔍 kubectl config view:"
kubectl config view --minify

# Verify cluster connectivity
echo "🔍 Verifying cluster connectivity..."
kubectl get nodes

echo "✅ Kubeconfig setup complete!"
echo "📊 Cluster status:"
kubectl get pods --all-namespaces

echo "🎯 Ready to deploy applications!"