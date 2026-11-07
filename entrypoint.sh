#!/usr/bin/env bash
set -euo pipefail

CD="${COMFY_DIR:-/comfyui}"
COMFY_PORT="${COMFY_PORT:-9188}"
WORKER_PORT="${WORKER_PORT:-8188}"
TOKEN="${WAN_WORKER_TOKEN:-}"

echo "[entrypoint] ComfyUI dir: $CD"
echo "[entrypoint] ComfyUI port: $COMFY_PORT, proxy port: $WORKER_PORT"
echo "[entrypoint] Token: $([ -n "$TOKEN" ] && echo set || echo MISSING)"

mkdir -p "$CD/models/loras"

python3 "$CD/main.py" --listen 127.0.0.1 --port "$COMFY_PORT" --disable-auto-launch &
COMFY_PID=$!

for _ in $(seq 1 240); do
  if curl -fsS "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1; then
    echo "[entrypoint] ComfyUI is up"
    break
  fi
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: ComfyUI exited" >&2
    wait "$COMFY_PID"
    exit 1
  fi
  sleep 2
done

export WORKER_TOKEN="$TOKEN"
export COMFY_PORT
export LORA_DIR="$CD/models/loras"
exec python3 /proxy.py "$WORKER_PORT"
