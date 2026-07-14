#!/usr/bin/env bash
# Bootstraps third-party dependencies for VoxLocal:
#   1. Verifies Xcode Command Line Tools.
#   2. Obtains cmake (project-local download if not installed system-wide).
#   3. Clones whisper.cpp pinned to a stable tag.
#   4. Builds whisper-cli with Metal acceleration.
# No sudo, no global package manager. Everything lands in vendor/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_clt
log "Xcode tools: $(xcode-select -p)"
log "Swift: $(swift --version 2>/dev/null | head -1)"

mkdir -p "$VENDOR_DIR/tools"

# --- cmake -------------------------------------------------------------
if CMAKE_BIN="$(find_cmake)"; then
  log "cmake found: $CMAKE_BIN"
else
  CMAKE_TARBALL="cmake-$CMAKE_VERSION-macos-universal.tar.gz"
  CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$CMAKE_TARBALL"
  log "cmake not installed; downloading project-local cmake $CMAKE_VERSION (~45 MB) from cmake.org GitHub releases"
  curl -fL --retry 3 -o "$VENDOR_DIR/tools/$CMAKE_TARBALL" "$CMAKE_URL"
  tar -xzf "$VENDOR_DIR/tools/$CMAKE_TARBALL" -C "$VENDOR_DIR/tools"
  rm -f "$VENDOR_DIR/tools/$CMAKE_TARBALL"
  CMAKE_BIN="$(find_cmake)" || die "project-local cmake extraction failed"
  log "cmake ready: $CMAKE_BIN"
fi

# --- whisper.cpp -------------------------------------------------------
if [[ -d "$WHISPER_DIR/.git" ]]; then
  CURRENT_TAG="$(git -C "$WHISPER_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
  if [[ "$CURRENT_TAG" == "$WHISPER_TAG" ]]; then
    log "whisper.cpp already cloned at $WHISPER_TAG"
  else
    log "whisper.cpp present at '$CURRENT_TAG'; re-checking out $WHISPER_TAG"
    git -C "$WHISPER_DIR" fetch --depth 1 origin "refs/tags/$WHISPER_TAG:refs/tags/$WHISPER_TAG" || true
    git -C "$WHISPER_DIR" checkout "refs/tags/$WHISPER_TAG" --
  fi
else
  log "Cloning whisper.cpp $WHISPER_TAG (shallow)"
  git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
fi
log "whisper.cpp commit: $(git -C "$WHISPER_DIR" rev-parse HEAD)"

# --- build whisper-cli -------------------------------------------------
"$REPO_ROOT/scripts/build_whisper.sh"

log "Bootstrap complete."
log "Next steps: ./scripts/test.sh && ./scripts/build_app.sh && ./scripts/run.sh"
