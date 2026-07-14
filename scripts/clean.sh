#!/usr/bin/env bash
# Removes build products. Keeps vendor sources and downloaded models.
# Use --all to also remove vendor builds and project-local tools.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Removing .build and dist…"
rm -rf "$REPO_ROOT/.build" "$DIST_DIR"

if [[ "${1:-}" == "--all" ]]; then
  log "Removing whisper.cpp build and project-local tools…"
  rm -rf "$WHISPER_DIR/build" "$VENDOR_DIR/tools"
fi

log "Clean complete. (Models in '$MODELS_DIR' are never touched by this script.)"
