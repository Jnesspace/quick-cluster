#!/usr/bin/env bash
# Generate the RSA private key Spacelift uses to encrypt sensitive data at rest,
# and print it base64-encoded on a single line for ENCRYPTION_RSA_PRIVATE_KEY.
#
#   ./scripts/gen-rsa-key.sh
#   # then paste the output into .env as ENCRYPTION_RSA_PRIVATE_KEY=...
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required" >&2
  exit 1
fi

key="$(openssl genrsa 2048 2>/dev/null)"
printf '%s' "$key" | base64 | tr -d '\n'
echo
