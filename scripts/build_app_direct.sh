#!/usr/bin/env bash
# Fallback build for machines where SwiftPM is unusable — e.g. Intel Macs on
# macOS 13 with Command Line Tools 14.x, where `swift build` dies with
# "xcrun: unable to lookup item 'PlatformPath'" (CLT has no platform dir).
#
# Compiles VoxLocalCore + the app entry point directly with swiftc as a
# single module, assembles dist/VoxLocal.app and ad-hoc signs it.
# Produces the same bundle layout as build_app.sh, but with
# LSMinimumSystemVersion 13.0 and no Metal requirement.
#
# Prerequisites: ./scripts/bootstrap.sh (whisper-cli must be built).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_clt
cd "$REPO_ROOT"

[[ -x "$WHISPER_CLI" ]] || die "whisper-cli not built. Run ./scripts/bootstrap.sh first."

VERSION="1.0.0"
BUILD_NUMBER="1"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"
BUILD_DIR="$REPO_ROOT/.build/direct"
GEN_DIR="$BUILD_DIR/generated"
mkdir -p "$GEN_DIR"

# --- generated sources -------------------------------------------------
# SwiftPM would generate Bundle.module; replicate it for the single-module
# build so L10n can find the localization bundle inside the .app.
cat > "$GEN_DIR/BundleModuleShim.swift" <<'EOF'
import Foundation

extension Bundle {
    static let module: Bundle = {
        let bundleName = "VoxLocal_VoxLocalCore"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName + ".bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.main
    }()
}
EOF

# Everything is one module here, so the `import VoxLocalCore` line must go.
sed 's/^import VoxLocalCore$//' "$REPO_ROOT/Sources/VoxLocal/VoxLocalMain.swift" \
  > "$GEN_DIR/VoxLocalMain.swift"

# --- compile -----------------------------------------------------------
log "Compiling with swiftc for $TARGET (single module, no SwiftPM)…"
CORE_SOURCES=()
while IFS= read -r f; do CORE_SOURCES+=("$f"); done \
  < <(find "$REPO_ROOT/Sources/VoxLocalCore" -name '*.swift' | sort)

swiftc -O -target "$TARGET" -parse-as-library -enable-bare-slash-regex \
  "${CORE_SOURCES[@]}" \
  "$GEN_DIR/VoxLocalMain.swift" \
  "$GEN_DIR/BundleModuleShim.swift" \
  -o "$BUILD_DIR/$APP_NAME"

# --- assemble bundle ---------------------------------------------------
log "Assembling ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$WHISPER_CLI" "$APP_BUNDLE/Contents/MacOS/whisper-cli"

RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/VoxLocal_VoxLocalCore.bundle"
mkdir -p "$RESOURCE_BUNDLE"
cp -R "$REPO_ROOT/Sources/VoxLocalCore/Resources/ru.lproj" \
      "$REPO_ROOT/Sources/VoxLocalCore/Resources/en.lproj" \
      "$RESOURCE_BUNDLE/"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleDisplayName</key>
    <string>VoxLocal</string>
    <key>CFBundleExecutable</key>
    <string>VoxLocal</string>
    <key>CFBundleIdentifier</key>
    <string>org.voxlocal.VoxLocal</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VoxLocal</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoxLocal записывает вашу речь для локального распознавания. Звук не покидает этот Mac. / VoxLocal records your speech for on-device transcription. Audio never leaves this Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 VoxLocal contributors. MIT License.</string>
</dict>
</plist>
PLIST

mkdir -p "$APP_BUNDLE/Contents/Resources/ru.lproj" "$APP_BUNDLE/Contents/Resources/en.lproj"
cat > "$APP_BUNDLE/Contents/Resources/ru.lproj/InfoPlist.strings" <<'EOF'
"NSMicrophoneUsageDescription" = "VoxLocal записывает вашу речь для локального распознавания. Звук не покидает этот Mac.";
EOF
cat > "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings" <<'EOF'
"NSMicrophoneUsageDescription" = "VoxLocal records your speech for on-device transcription. Audio never leaves this Mac.";
EOF

log "Ad-hoc signing…"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep "$APP_BUNDLE" || die "codesign verification failed"

log "Done: $APP_BUNDLE"
log "Launch with: ./scripts/run.sh  (or: open \"$APP_BUNDLE\")"
