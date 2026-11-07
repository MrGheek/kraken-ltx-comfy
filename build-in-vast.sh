#!/usr/bin/env bash
# Build the private LTX-2.5 image on a Vast.ai (or any root linux/amd64)
# container without a Docker daemon, using buildah in chroot/vfs mode.
#
# Required env:
#   GHCR_USER, GHCR_TOKEN   (write:packages)
#   HF_TOKEN                (accepted Lightricks/LTX-2.5 access)
#
# Usage on the builder instance:
#   GHCR_USER=... GHCR_TOKEN=... HF_TOKEN=... ./build-in-vast.sh
set -euo pipefail

: "${GHCR_USER:?set GHCR_USER}"
: "${GHCR_TOKEN:?set GHCR_TOKEN (write:packages)}"
: "${HF_TOKEN:?set HF_TOKEN (accepted Lightricks/LTX-2.5 access)}"

IMAGE="${IMAGE:-ghcr.io/mrgheek/kraken-ltx-comfy:latest}"
REPO="${REPO:-https://github.com/MrGheek/kraken-ltx-comfy.git}"

if ! command -v buildah >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates buildah
fi

rm -rf /workspace/kraken-ltx-comfy
git clone --depth 1 "$REPO" /workspace/kraken-ltx-comfy
cd /workspace/kraken-ltx-comfy

mkdir -p ~/.config/containers
AUTH="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)"
cat > ~/.config/containers/auth.json <<EOF
{"auths":{"ghcr.io":{"auth":"$AUTH"}}}
EOF

TOKEN_FILE="$(mktemp)"
echo "$HF_TOKEN" > "$TOKEN_FILE"
trap 'rm -f "$TOKEN_FILE"' EXIT

echo "[build] building $IMAGE with buildah (chroot/vfs)"
buildah --storage-driver vfs bud \
  --format docker \
  --layers \
  --isolation chroot \
  --secret id=hf_token,src="$TOKEN_FILE" \
  -t "$IMAGE" \
  .

echo "[build] pushing $IMAGE"
buildah push "$IMAGE" "docker://$IMAGE"

echo "[build] done. Keep the GHCR package private."
