# Kraken LTX-2.5 ComfyUI image

Standalone, **private** worker image for LTX-2.5 (video + synchronized audio),
built for Kraken Studios' `WAN_DEPLOY_MODE=comfy_ltx` path.

This repository is public as a **build recipe**. The image itself contains
LTX-2.5 weights and must stay private; see the license section.

## What's inside

- `vastai/comfy:v0.18.2-cuda-12.9-py312` (ComfyUI + CUDA)
- LTX-2.5 ComfyUI int8 pack:
  - `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors`
  - `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors`
  - `ltx-2.5-video-vae-bf16.safetensors`
  - `ltx-2.5-audio-vae-bf16.safetensors`
  - spatial upscaler + duration head (optional nodes)
- `ComfyUI_essentials` for `ETN_LoadImageBase64` (I2V conditioning)
- `entrypoint.sh`: ComfyUI on `127.0.0.1:9188`, auth proxy on `0.0.0.0:8188`
- `proxy.py`: Bearer-token proxy + `/lora/upload`

## Build requirements

- `linux/amd64`
- **≥ 80 GB free disk** (final image ~40 GB)
- Docker BuildKit
- `HF_TOKEN` for the gated `Lightricks/LTX-2.5` model, after accepting the
  license on Hugging Face.

GitHub-hosted runners usually do **not** have enough disk for this image. Use a
Vast.ai instance or a self-hosted runner (the workflow takes a `runner` input).

## Build and push

```bash
# 1. Accept the LTX-2.5 license on huggingface.co/Lightricks/LTX-2.5
# 2. Save a read token
echo "$HF_TOKEN" > /tmp/hf_token

# 3. Build and push (private GHCR package)
export IMAGE=ghcr.io/<owner>/kraken-ltx-comfy:latest
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
docker buildx build \
  --platform linux/amd64 \
  --secret id=hf_token,src=/tmp/hf_token \
  -t "$IMAGE" --push .
```

The HF token is mounted as a BuildKit secret and is never written into a layer.

## Configure Kraken Studios

```bash
WAN_DEPLOY_MODE=comfy_ltx
WAN_WORKER_IMAGE=ghcr.io/<owner>/kraken-ltx-comfy:latest
WAN_WORKER_PREBAKED=true
WAN_WORKER_PORT=8188
WAN_WORKER_GPU_NAME=RTX A6000        # or L40S (48GB)
WAN_WORKER_MAX_DPH=0.50
WAN_WORKER_MIN_INET_DOWN_MBPS=500
WAN_WORKER_IDLE_TIMEOUT_MIN=30
NATIVE_AUDIO_ENABLED=true
GHCR_USERNAME=<github-user>
GHCR_PAT=<token-with-read:packages>
```

`comfy_ltx` requires `WAN_WORKER_PREBAKED=true`; the provisioner will not run the
Wan onstart download path.

## Audio integration

LTX-2.5 emits synchronized audio. Kraken Studios extracts it as the
`audio_native` stem:

- It is a **bed** (room tone / foley / ambience), **not** a replacement for
  dialogue.
- Dialogue TTS remains authoritative and keeps its emotion-aware prosody
  (valence/arousal → speed, pitch, emphasis, pauses).
- The native bed's gain and tags are derived from the same performance graphs
  (`resolveNativeAudioProfile`), then ducked under dialogue in `assembleAudio`.
- The generation prompt asks for ambience/foley and **no spoken dialogue,
  narration, or music**, so it doesn't fight the TTS/music stems.

## License

LTX-2.5 is distributed under the **LTX-2.x Community License**:

- Free for commercial/production use under **$10M annual revenue** (entity-wide,
  including subsidiaries/affiliates).
- Above that, a paid commercial agreement is required.
- The model is gated; transfer of fine-tunes may require a paid license.

Do **not** publish this image or its weights publicly without reviewing the
LICENSE. Keep the GHCR package private and pull it with `GHCR_USERNAME` /
`GHCR_PAT`.
