# syntax=docker/dockerfile:1.7
#
# Pre-baked LTX-2.5 ComfyUI worker for Kraken Studios.
#
# This image is intended to be built and pushed to a PRIVATE registry. LTX-2.5
# weights are gated and distributed under the LTX-2.x Community License; do not
# publish this image or its weights publicly without reviewing the LICENSE.
#
# Build requires linux/amd64 and >= 80 GB free disk (~40 GB final image).
# GitHub-hosted runners generally do not have enough disk; use a Vast.ai
# instance or a self-hosted runner.
#
# Model pack: Lightricks/LTX-2.5 (ComfyUI int8 variants)
FROM vastai/comfy:v0.18.2-cuda-12.9-py312

ENV DEBIAN_FRONTEND=noninteractive \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    COMFY_PORT=9188 \
    WORKER_PORT=8188

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        git ffmpeg curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN if [ -d /opt/ComfyUI ]; then ln -sfn /opt/ComfyUI /comfyui; \
    elif [ -d /workspace/ComfyUI ]; then ln -sfn /workspace/ComfyUI /comfyui; \
    else echo "FATAL: ComfyUI not found in base image" >&2; exit 1; fi

RUN python3 -m pip install --no-cache-dir "huggingface_hub[cli]" hf_transfer

# ETN_LoadImageBase64 (I2V conditioning) comes from ComfyUI_essentials.
RUN set -eux; \
    CD=/comfyui; \
    ND="$CD/custom_nodes/ComfyUI_essentials"; \
    if [ ! -d "$ND" ]; then git clone --depth 1 https://github.com/cubiq/ComfyUI_essentials.git "$ND"; fi; \
    if [ -f "$ND/requirements.txt" ]; then \
      python3 -m pip install --no-cache-dir -r "$ND/requirements.txt"; \
    fi

# Each component is its own layer to stay under registry layer limits.
# The HF token is a BuildKit secret and is never persisted in an image layer.
RUN --mount=type=secret,id=hf_token \
    mkdir -p /comfyui/models/diffusion_models && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" \
    python3 -m huggingface_hub.commands.huggingface_cli download \
      Lightricks/LTX-2.5 \
      --local-dir /comfyui/models \
      --include "diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"

RUN --mount=type=secret,id=hf_token \
    mkdir -p /comfyui/models/text_encoders && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" \
    python3 -m huggingface_hub.commands.huggingface_cli download \
      Lightricks/LTX-2.5 \
      --local-dir /comfyui/models \
      --include "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"

RUN --mount=type=secret,id=hf_token \
    mkdir -p /comfyui/models/vae && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" \
    python3 -m huggingface_hub.commands.huggingface_cli download \
      Lightricks/LTX-2.5 \
      --local-dir /comfyui/models \
      --include "vae/ltx-2.5-video-vae-bf16.safetensors" \
      --include "vae/ltx-2.5-audio-vae-bf16.safetensors"

RUN --mount=type=secret,id=hf_token \
    mkdir -p /comfyui/models/latent_upscale_models /comfyui/models/model_patches && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" \
    python3 -m huggingface_hub.commands.huggingface_cli download \
      Lightricks/LTX-2.5 \
      --local-dir /comfyui/models \
      --include "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors" && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" \
    python3 -m huggingface_hub.commands.huggingface_cli download \
      Lightricks/LTX-2.5 \
      --local-dir /comfyui/models \
      --include "model_patches/ltx-2.5-duration-head-bf16.safetensors"

RUN mkdir -p /comfyui/models/loras

COPY proxy.py /proxy.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=10s --start-period=600s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8188/system_stats >/dev/null || exit 1

CMD ["/entrypoint.sh"]
