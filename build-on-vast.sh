#!/usr/bin/env bash
# Build and push the private LTX-2.5 image from a linux/amd64 host.
# Intended for a Vast.ai instance or any machine with >= 80 GB free disk.
set -euo pipefail

: "${GHCR_USER:?set GHCR_USER}"
: "${GHCR_TOKEN:?set GHCR_TOKEN (write:packages)}"
: "${HF_TOKEN:?set HF_TOKEN (gated Lightricks/LTX-2.5 access)}"

IMAGE="${IMAGE:-ghcr.io/mrgheek/kraken-ltx-comfy:latest}"

echo "[build] logging in to ghcr.io as $GHCR_USER"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

TOKEN_FILE="$(mktemp)"
echo "$HF_TOKEN" > "$TOKEN_FILE"
trap 'rm -f "$TOKEN_FILE"' EXIT

echo "[build] building $IMAGE"
docker buildx build \
  --platform linux/amd64 \
  --secret id=hf_token,src="$TOKEN_FILE" \
  -t "$IMAGE" \
  --push .

echo "[build] pushed $IMAGE"
echo "[build] keep the GHCR package private; configure GHCR_USERNAME/GHCR_PAT in the app."
