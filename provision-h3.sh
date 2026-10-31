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

# --- 3. 模型 (aria2 多连接并发下载，单连接 curl 实测只有 11-14MB/s) ---
apt-get install -y -q aria2 >/dev/null 2>&1
HDR=(); [ -n "$HF_TOKEN" ] && HDR=(--header "Authorization: Bearer $HF_TOKEN")
# 下载前先测速：用 LoRA 小文件的前 ~300MB，低于 MIN_MBPS 就报警并退出，方便立即换机器
MIN_MBPS="${MIN_MBPS:-40}"
speedtest() {
  local d; d=$(mktemp -d)
  local t0=$(date +%s.%N)
  aria2c -x16 -s16 -k4M --file-allocation=none --console-log-level=error --summary-interval=0     "${HDR[@]}" --max-download-limit=0 -d "$d" -o st.bin --lowest-speed-limit=0 --timeout=20     --stop=20 "https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors" >/dev/null 2>&1
  local t1=$(date +%s.%N) sz; sz=$(stat -c %s "$d/st.bin" 2>/dev/null || echo 0)
  rm -rf "$d"
  python3 -c "print(round($sz/1e6/max($t1-$t0,0.1),1))"
}
SPEED=$(speedtest); say "speedtest: ${SPEED} MB/s (min ${MIN_MBPS})"
if python3 -c "import sys; sys.exit(0 if $SPEED >= $MIN_MBPS else 1)"; then :; else
  say "ERROR: download too slow (${SPEED} MB/s < ${MIN_MBPS}); destroy this instance and rent another"; exit 3; fi
dl() { # repo path-in-repo dest-dir
  local out="$COMFY/models/$3/$(basename "$2")"
  mkdir -p "$(dirname "$out")"; say "download $1/$2"
  aria2c -x16 -s16 -k4M -c --file-allocation=none --console-log-level=warn --summary-interval=0     "${HDR[@]}" -d "$(dirname "$out")" -o "$(basename "$out")"     "https://huggingface.co/$1/resolve/main/$2" >>"$LOG" 2>&1 || say "ERROR: download failed $2"
  say "  -> $(du -h "$out" 2>/dev/null | cut -f1)"
}
dl Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors diffusion_models
dl Comfy-Org/MiniMax-H3 text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors text_encoders
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_fp16.safetensors vae
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors vae
dl lightx2v/Minimax-h3-Turbo minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors loras

say "DONE in $(( $(date +%s) - t0 ))s"
df -h "$WORKSPACE" | tail -1 | tee -a "$LOG"
