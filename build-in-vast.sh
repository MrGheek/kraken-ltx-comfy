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
KANIKO_IMAGE="${KANIKO_IMAGE:-ghcr.io/mrgheek/kaniko-executor:debug}"

for cmd in git curl tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates tar
    break
  fi
done

if [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --depth 1 "$REPO" "$REPO_DIR"
fi
cd "$REPO_DIR"

AUTH="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)"
mkdir -p /kaniko/.docker /root/.docker ~/.config/containers
cat > /kaniko/.docker/config.json <<EOF
{"auths":{"ghcr.io":{"username":"$GHCR_USER","password":"$GHCR_TOKEN","auth":"$AUTH"}}}
EOF
cp /kaniko/.docker/config.json /root/.docker/config.json
export DOCKER_CONFIG=/kaniko/.docker
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

# kaniko does not need a daemon or user namespaces. The amd64 executor is
# published as a release asset so Vast hosts never need gcr.io access.
TOOLS_TGZ_URL="${TOOLS_TGZ_URL:-https://codeload.github.com/MrGheek/kraken-tools/tar.gz/refs/heads/main}"
if [ ! -x /usr/local/bin/kaniko ]; then
  echo "[build] downloading kaniko tools"
  curl -fL --retry 2 --max-time 180 -o /tmp/tools.tar.gz "$TOOLS_TGZ_URL" || { echo "TOOLS_DOWNLOAD_FAILED"; exit 1; }
  rm -rf /tmp/kraken-tools && mkdir -p /tmp/kraken-tools
  tar -xzf /tmp/tools.tar.gz -C /tmp/kraken-tools --strip-components=1 || { echo "TOOLS_EXTRACT_FAILED"; exit 1; }
  install -m 0755 /tmp/kraken-tools/kaniko-executor /usr/local/bin/kaniko || { echo "KANIKO_INSTALL_FAILED"; exit 1; }
fi

echo "[build] docker config (redacted):"
sed -E 's/("auth"|"password"):"[^"]*"/\1:"***"/g' /kaniko/.docker/config.json || true

echo "[build] building and pushing $IMAGE with kaniko"
/usr/local/bin/kaniko \
  --context="dir://$REPO_DIR" \
  --dockerfile="Dockerfile.buildah" \
  --destination="$IMAGE" \
  --build-arg "HF_TOKEN=$HF_TOKEN" \
  --verbosity=info

echo "[build] done. Keep the GHCR package private."
