#!/usr/bin/env bash
# Downloads a ggml Whisper model from the official whisper.cpp Hugging Face
# repository into the user's model folder. Shows the approximate size and
# asks for confirmation (skip with -y).
#
# Usage: ./scripts/download_model.sh [model] [-y]
#   model: tiny | tiny.en | base | base.en | small | small.en | medium | large-v3 | large-v3-turbo
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODEL="${1:-base}"
ASSUME_YES="${2:-}"

case "$MODEL" in
  tiny|tiny.en)        SIZE="~78 MB" ;;
  base|base.en)        SIZE="~148 MB" ;;
  small|small.en)      SIZE="~488 MB" ;;
  medium)              SIZE="~1.5 GB" ;;
  large-v3)            SIZE="~3.1 GB" ;;
  large-v3-turbo)      SIZE="~1.6 GB" ;;
  *) die "unknown model '$MODEL'. Valid: tiny tiny.en base base.en small small.en medium large-v3 large-v3-turbo" ;;
esac

URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
DEST="$MODELS_DIR/ggml-$MODEL.bin"

if [[ -f "$DEST" ]]; then
  log "model already installed: $DEST"
  exit 0
fi

log "Model:       $MODEL ($SIZE)"
log "Source:      $URL"
log "Destination: $DEST"
if [[ "$ASSUME_YES" != "-y" ]]; then
  read -r -p "Download now? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { log "aborted"; exit 1; }
fi

mkdir -p "$MODELS_DIR"
curl -fL --retry 3 --progress-bar -o "$DEST.partial" "$URL"
mv "$DEST.partial" "$DEST"

# Integrity: the ggml container magic is the first four bytes.
MAGIC="$(head -c 4 "$DEST" | xxd -p)"
if [[ "$MAGIC" != "6c6d6767" ]]; then
  rm -f "$DEST"
  die "downloaded file failed the ggml magic check (got: $MAGIC); removed"
fi
log "model installed: $DEST"
