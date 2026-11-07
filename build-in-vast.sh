#!/usr/bin/env bash
# Build the private LTX-2.5 image on a Vast.ai (or any root linux/amd64)
# container without Docker or user namespaces.
#
# Primary builder: kaniko (executor binary extracted with skopeo).
# Fallback: buildah --isolation chroot (only if the host permits user namespaces).
#
# Required env:
#   GHCR_USER, GHCR_TOKEN   (write:packages)
#   HF_TOKEN                (accepted Lightricks/LTX-2.5 access)
set -euo pipefail

: "${GHCR_USER:?set GHCR_USER}"
: "${GHCR_TOKEN:?set GHCR_TOKEN (write:packages)}"
: "${HF_TOKEN:?set HF_TOKEN (accepted Lightricks/LTX-2.5 access)}"

IMAGE="${IMAGE:-ghcr.io/mrgheek/kraken-ltx-comfy:latest}"
REPO="${REPO:-https://github.com/MrGheek/kraken-ltx-comfy.git}"
REPO_DIR="${REPO_DIR:-/workspace/kraken-ltx-comfy}"
BUILDER="${BUILDER:-kaniko}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates skopeo jq

if [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --depth 1 "$REPO" "$REPO_DIR"
fi
cd "$REPO_DIR"

AUTH="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)"
mkdir -p /kaniko/.docker ~/.config/containers
cat > /kaniko/.docker/config.json <<EOF
{"auths":{"ghcr.io":{"username":"$GHCR_USER","password":"$GHCR_TOKEN","auth":"$AUTH"}}}
EOF
cat > ~/.config/containers/auth.json <<EOF
{"auths":{"ghcr.io":{"auth":"$AUTH"}}}
EOF

if [ "$BUILDER" = "buildah" ]; then
  if ! command -v buildah >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq buildah
  fi
  echo "[build] building $IMAGE with buildah (chroot/vfs)"
  buildah --storage-driver vfs bud \
    --format docker \
    --layers \
    --isolation chroot \
    --userns host \
    --build-arg HF_TOKEN="$HF_TOKEN" \
    -f Dockerfile.buildah \
    -t "$IMAGE" \
    .
  echo "[build] pushing $IMAGE"
  buildah push "$IMAGE" "docker://$IMAGE"
  exit 0
fi

# kaniko does not need a daemon or user namespaces.
if [ ! -x /usr/local/bin/kaniko ]; then
  echo "[build] fetching kaniko executor"
  rm -rf /tmp/kaniko /tmp/kaniko-root
  skopeo copy docker://gcr.io/kaniko-project/executor:debug dir:/tmp/kaniko
  mkdir -p /tmp/kaniko-root
  for layer in $(jq -r '.layers[].digest' /tmp/kaniko/manifest.json); do
    tar -xf "/tmp/kaniko/blobs/sha256/${layer#sha256:}" -C /tmp/kaniko-root 2>/dev/null || true
  done
  EXECUTOR="$(find /tmp/kaniko-root -type f -name executor | head -1)"
  if [ -z "$EXECUTOR" ]; then
    echo "[build] FATAL: kaniko executor not found in extracted image" >&2
    exit 1
  fi
  install -m 0755 "$EXECUTOR" /usr/local/bin/kaniko
fi

echo "[build] building and pushing $IMAGE with kaniko"
/usr/local/bin/kaniko \
  --context="dir://$REPO_DIR" \
  --dockerfile="Dockerfile.buildah" \
  --destination="$IMAGE" \
  --build-arg "HF_TOKEN=$HF_TOKEN" \
  --verbosity=info

echo "[build] done. Keep the GHCR package private."
