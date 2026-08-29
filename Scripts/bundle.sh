#!/usr/bin/env bash
# Wraps the SwiftPM executable in a .app bundle.
# macOS ties Accessibility and microphone grants to the bundle identifier,
# so running the bare binary re-prompts (and re-fails) every single launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/Murmur.app"
BIN="$ROOT/.build/$CONFIG/Murmur"

[ -x "$BIN" ] || { echo "Build first: swift build -c $CONFIG"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Murmur</string>
    <key>CFBundleDisplayName</key><string>Murmur</string>
    <key>CFBundleIdentifier</key><string>com.fintonlabs.murmur</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Murmur</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur transcribes your speech on this Mac. Audio never leaves the device.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. TCC invalidates a grant when the binary changes, so the app
# must be re-signed on every rebuild or permissions silently stop working.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "Built $APP"
