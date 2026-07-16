#!/usr/bin/env bash
# Builds the pinned whisper.cpp as a static whisper-cli binary with Metal
# acceleration (Apple Silicon) for the current architecture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ -d "$WHISPER_DIR" ]] || die "whisper.cpp not found at $WHISPER_DIR — run ./scripts/bootstrap.sh first"
CMAKE_BIN="$(find_cmake)" || die "cmake not found — run ./scripts/bootstrap.sh first"

ARCH="$(uname -m)"
METAL_FLAGS=()
if [[ "$ARCH" == "arm64" ]]; then
  # Embed the Metal shader library into the binary so a single file can be
  # copied into the .app bundle without a companion .metallib.
  METAL_FLAGS=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  log "Building for Apple Silicon with Metal"
else
  METAL_FLAGS=(-DGGML_METAL=OFF)
  log "Building for $ARCH without Metal"
fi

"$CMAKE_BIN" -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  "${METAL_FLAGS[@]}"

"$CMAKE_BIN" --build "$WHISPER_DIR/build" --config Release --target whisper-cli --target whisper-server -j "$(sysctl -n hw.ncpu)"

[[ -x "$WHISPER_CLI" ]] || die "build finished but $WHISPER_CLI is missing"
log "whisper-cli built: $WHISPER_CLI"
"$WHISPER_CLI" --help >/dev/null 2>&1 || die "whisper-cli does not run"
log "whisper-cli smoke check passed"

WHISPER_SERVER="$WHISPER_DIR/build/bin/whisper-server"
[[ -x "$WHISPER_SERVER" ]] || die "build finished but $WHISPER_SERVER is missing"
log "whisper-server built: $WHISPER_SERVER"
