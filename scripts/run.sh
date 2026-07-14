#!/usr/bin/env bash
# Launches the packaged app (builds it first if missing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
  log "app bundle missing; building it first"
  "$REPO_ROOT/scripts/build_app.sh"
fi

log "Launching $APP_BUNDLE"
open "$APP_BUNDLE"
log "VoxLocal lives in the menu bar (microphone icon). No Dock icon appears by design."
