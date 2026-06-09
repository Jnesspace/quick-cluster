#!/usr/bin/env bash
#
# push-selfhosted-images.sh  (manual ops helper — run once, with AWS creds + docker)
#
# Loads the Spacelift self-hosted images from the release bundle and pushes them
# to your ECR (same AWS account as the EKS cluster, so nodes pull via their IAM
# role — no imagePullSecret needed). Then prints the image refs to put in your
# values-secrets.yaml.
#
# Usage:
#   push-selfhosted-images.sh <ecr-registry> <region> <bundle>
#     <ecr-registry> : <acct-id>.dkr.ecr.<region>.amazonaws.com
#     <region>       : e.g. eu-west-1  (match your aws_default_region)
#     <bundle>       : local path to self-hosted-v5.1.2.tar.gz, an s3:// uri, or a presigned URL
#
# NOTE: this assumes the bundle ships images as docker-archive *.tar files (the
# common layout). If your v5.1.2 bundle includes its own push tooling/README,
# prefer that. Run `tar tzf self-hosted-v5.1.2.tar.gz | head` to check the layout.

set -euo pipefail

ECR="${1:?ecr registry required, e.g. 123456789012.dkr.ecr.eu-west-1.amazonaws.com}"
REGION="${2:?region required, e.g. eu-west-1}"
BUNDLE="${3:?bundle path/s3-uri/url required}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"

# 1) Obtain the bundle
case "$BUNDLE" in
  s3://*)   echo "⬇️  aws s3 cp $BUNDLE ..."; aws s3 cp "$BUNDLE" bundle.tar.gz ;;
  http*://*) echo "⬇️  curl $BUNDLE ...";      curl -fsSL "$BUNDLE" -o bundle.tar.gz ;;
  *)        echo "📦 using local $BUNDLE";     cp "$BUNDLE" bundle.tar.gz ;;
esac

echo "📂 Extracting..."
mkdir -p extracted && tar -xzf bundle.tar.gz -C extracted
echo "Bundle top-level contents:"; ls -la extracted | sed 's/^/    /'

# 2) ECR login
echo "🔑 Logging in to ECR ($ECR)..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

# 3) Load every docker-archive tar, retag to ECR, push
mapfile -t IMG_TARS < <(find extracted -type f -name '*.tar')
if [ "${#IMG_TARS[@]}" -eq 0 ]; then
  echo "⚠️  No *.tar image archives found in the bundle. Check the bundle layout /"
  echo "    its README — it may ship a dedicated push script instead." >&2
  exit 1
fi

declare -a PUSHED
for t in "${IMG_TARS[@]}"; do
  echo "🧩 docker load < $t"
  # docker load prints e.g. "Loaded image: spacelift/backend:v5.1.2"
  loaded="$(docker load -i "$t" | sed -nE 's/^Loaded image: (.+)$/\1/p')"
  for src in $loaded; do
    repo="${src%:*}"; tag="${src##*:}"
    ecr_repo="$(echo "$repo" | sed -E 's#^.*/##; s#[^a-zA-Z0-9._/-]#-#g')"   # last path segment -> ECR repo
    dst="${ECR}/${ecr_repo}:${tag}"
    echo "   → $src  =>  $dst"
    aws ecr describe-repositories --region "$REGION" --repository-names "$ecr_repo" >/dev/null 2>&1 \
      || aws ecr create-repository --region "$REGION" --repository-name "$ecr_repo" >/dev/null
    docker tag "$src" "$dst"
    docker push "$dst"
    PUSHED+=("$dst")
  done
done

echo
echo "✅ Pushed:"; printf '   %s\n' "${PUSHED[@]}"
echo
echo "Now set these in values-secrets.yaml (match backend + launcher):"
echo "    spacelift.shared.image: <the backend ref above>"
echo "    launcher.image / launcher.tag: <the launcher repo and tag above>"
