#!/usr/bin/env bash
# Runs the full automated test suite. The integration smoke test skips with
# a precise message when whisper-cli or a model is not installed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_clt
cd "$REPO_ROOT"

log "swift test ..."
swift test "$@"
