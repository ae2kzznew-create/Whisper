#!/usr/bin/env bash
# Builds VoxLocal in release mode and assembles a runnable, ad-hoc signed
# .app bundle at dist/VoxLocal.app.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_clt
cd "$REPO_ROOT"

[[ -x "$WHISPER_CLI" ]] || die "whisper-cli not built. Run ./scripts/bootstrap.sh first."

VERSION="1.0.0"
BUILD_NUMBER="1"

log "Building Swift package (release)…"
swift build -c release --product VoxLocal

BIN="$REPO_ROOT/.build/release/VoxLocal"
RESOURCE_BUNDLE="$REPO_ROOT/.build/release/VoxLocal_VoxLocalCore.bundle"
[[ -x "$BIN" ]] || die "release binary missing at $BIN"
[[ -d "$RESOURCE_BUNDLE" ]] || die "resource bundle missing at $RESOURCE_BUNDLE"

log "Assembling ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$WHISPER_CLI" "$APP_BUNDLE/Contents/MacOS/whisper-cli"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

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
    <string>14.0</string>
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

# Localized permission strings.
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
