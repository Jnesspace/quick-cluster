#!/usr/bin/env bash
#
# stash-selfhosted-release.sh  (manual ops helper — run with AWS creds)
#
# Downloads the Spacelift self-hosted release artifacts from their (expiring)
# presigned URLs, verifies the SHA256SUMS, and uploads all three to an S3 bucket
# you control so you can reuse them after tearing the cluster down.
#
# Use a bucket that is NOT managed by these stacks (the kubeconfig bucket is
# force-destroyed on teardown) so the artifacts actually persist.
#
# Usage:
#   stash-selfhosted-release.sh <dest-s3-uri> <tarball-url> <sha256sums-url> <sig-url>
# Example:
#   stash-selfhosted-release.sh s3://my-persistent-bucket/spacelift/v5.1.2 \
#     "<presigned tar.gz>" "<presigned SHA256SUMS>" "<presigned .sig>"

set -euo pipefail

DEST="${1:?dest s3 uri required, e.g. s3://bucket/prefix}"
TARBALL_URL="${2:?tarball presigned url required}"
SUMS_URL="${3:?SHA256SUMS presigned url required}"
SIG_URL="${4:?SHA256SUMS.sig presigned url required}"
DEST="${DEST%/}"
VER="self-hosted-v5.1.2.tar.gz"

sha256() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"

echo "⬇️  Downloading release artifacts..."
curl -fsSL "$TARBALL_URL" -o "$VER"
curl -fsSL "$SUMS_URL"    -o "${VER}_SHA256SUMS"
curl -fsSL "$SIG_URL"     -o "${VER}_SHA256SUMS.sig"

echo "🔎 Verifying checksum..."
EXPECTED="$(grep 'tar.gz' "${VER}_SHA256SUMS" | awk '{print $1}' | head -1)"
ACTUAL="$(sha256 "$VER")"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "❌ checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi
echo "✅ checksum ok ($ACTUAL)"

echo "⬆️  Uploading to ${DEST}/ ..."
aws s3 cp "$VER"                 "${DEST}/${VER}"
aws s3 cp "${VER}_SHA256SUMS"    "${DEST}/${VER}_SHA256SUMS"
aws s3 cp "${VER}_SHA256SUMS.sig" "${DEST}/${VER}_SHA256SUMS.sig"

echo "🎉 Stashed. Reuse later (no expiry) with:"
echo "    aws s3 cp ${DEST}/${VER} ."
