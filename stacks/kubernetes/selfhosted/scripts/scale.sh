#!/usr/bin/env bash
# Scale Spacelift app components up or down.
#
#   ./scripts/scale.sh server 3
#   ./scripts/scale.sh drain 2
#
# This is an immediate `kubectl scale`. To make it survive the next
# `helmfile apply`, also update SERVER_REPLICAS / DRAIN_REPLICAS in your .env
# (or environments/default.yaml.gotmpl).
set -euo pipefail

NS="${K8S_NAMESPACE:-spacelift}"

usage() {
  cat >&2 <<USAGE
Usage: $0 <component> <replicas>

Components:
  server      Spacelift API / frontend / MQTT  (safe to scale > 1)
  drain       async background processing       (safe to scale > 1)
  scheduler   recurring task scheduler          (keep at 1)

Namespace is taken from \$K8S_NAMESPACE (default: spacelift).
USAGE
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

component="$1"
replicas="$2"

case "$component" in
  server|drain|scheduler) ;;
  *) echo "Unknown component: $component" >&2; usage; exit 1 ;;
esac

if ! [[ "$replicas" =~ ^[0-9]+$ ]]; then
  echo "replicas must be a non-negative integer" >&2
  exit 1
fi

kubectl -n "$NS" scale "deployment/spacelift-${component}" --replicas="$replicas"
echo "Scaled spacelift-${component} to ${replicas} replicas in namespace '${NS}'."
echo "Remember to update your .env for persistence across 'helmfile apply'."
