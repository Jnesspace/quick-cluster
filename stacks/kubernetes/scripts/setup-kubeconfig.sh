#!/bin/bash
set -e

echo "🔧 Setting up kubeconfig for Kubernetes deployment..."

# Check if S3 bucket is provided
if [ -z "$KUBECONFIG_S3_BUCKET" ]; then
    echo "❌ Error: KUBECONFIG_S3_BUCKET environment variable not set"
    exit 1
fi

# Create .kube directory
mkdir -p ~/.kube

# Download kubeconfig from S3
echo "📥 Downloading kubeconfig from S3..."
aws s3 cp s3://$KUBECONFIG_S3_BUCKET/kubeconfig-latest.yaml ~/.kube/config

# Set proper permissions
chmod 600 ~/.kube/config

# Debug: Show what we downloaded
echo "🔍 Contents of downloaded kubeconfig:"
echo "======================================"
cat ~/.kube/config
echo "======================================="

# Debug: Check server URL specifically
echo "🔍 Server URL in kubeconfig:"
grep "server:" ~/.kube/config || echo "No server URL found!"

# Export KUBECONFIG explicitly
export KUBECONFIG=~/.kube/config
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