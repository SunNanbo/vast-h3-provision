#!/bin/bash
# Vast.ai PROVISIONING_SCRIPT: ComfyUI + 官方 MiniMax H3 (I2VA / 首帧图生视频), 约 45GB.
# 镜像: vastai/comfy。只装官方权重 (Comfy-Org + lightx2v Turbo LoRA)，节点固定到 commit。
# 不含任何 token；HF_TOKEN 由 Vast 模板环境变量提供（官方仓库如非 gated 可不设）。
# 注意：同一脚本 URL 在一个实例上只执行一次；改了脚本要换 URL 或加 ?v=N。
set -o pipefail
source /venv/main/bin/activate 2>/dev/null

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="${COMFY:-$WORKSPACE/ComfyUI}"
LOG="$WORKSPACE/provision-h3.log"
t0=$(date +%s)
say() { echo "[provision-h3 +$(( $(date +%s) - t0 ))s] $*" | tee -a "$LOG"; }

# --- 1. 升级 ComfyUI (H3 原生节点在 comfy_extras/nodes_minimax_h3.py，需要较新版本) ---
say "update ComfyUI"
git -C "$COMFY" fetch --tags --quiet && git -C "$COMFY" checkout --quiet master 2>/dev/null \
  && git -C "$COMFY" pull --quiet --ff-only
pip install -q -r "$COMFY/requirements.txt" 2>&1 | tail -2
[ -f "$COMFY/comfy_extras/nodes_minimax_h3.py" ] || say "WARN: nodes_minimax_h3.py missing after update"

# --- 2. 自定义节点 (固定 commit) ---
node() { # repo sha
  local d="$COMFY/custom_nodes/$(basename "$1")"
  [ -d "$d/.git" ] || git clone --quiet "https://github.com/$1.git" "$d"
  git -C "$d" fetch --quiet origin "$2" 2>/dev/null; git -C "$d" checkout --quiet "$2" \
    || say "WARN: cannot pin $1@$2"
  [ -f "$d/requirements.txt" ] && pip install -q -r "$d/requirements.txt" 2>&1 | tail -1
  say "node $1 @ $2"
}
node Kosinkadink/ComfyUI-VideoHelperSuite 4d907bee61e92c2e65af3bd6383a4e4d356126d1
node kijai/ComfyUI-KJNodes ab72eda7ffad6280422d71ab7d54d3fb87c0ba18

# --- 3. 模型 (断点续传，不覆盖已完成文件) ---
AUTH=(); [ -n "$HF_TOKEN" ] && AUTH=(-H "Authorization: Bearer $HF_TOKEN")
dl() { # repo path-in-repo dest-dir
  local out="$COMFY/models/$3/$(basename "$2")"
  mkdir -p "$(dirname "$out")"
  say "download $1/$2"
  curl -L --fail --retry 5 --retry-delay 5 -C - "${AUTH[@]}" -o "$out" \
    "https://huggingface.co/$1/resolve/main/$2" 2>>"$LOG" || say "ERROR: download failed $2"
  say "  -> $(du -h "$out" 2>/dev/null | cut -f1)"
}
dl Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors diffusion_models
dl Comfy-Org/MiniMax-H3 text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors text_encoders
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_fp16.safetensors vae
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors vae
dl lightx2v/Minimax-h3-Turbo minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors loras

say "DONE in $(( $(date +%s) - t0 ))s"
df -h "$WORKSPACE" | tail -1 | tee -a "$LOG"
