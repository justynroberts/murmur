#!/usr/bin/env bash
# Wraps the SwiftPM executable in a signed .app bundle.
#
# macOS ties Accessibility and microphone grants to the bundle identifier AND to
# the binary's signature, so running the bare binary — or re-signing ad-hoc after
# each build — makes permissions silently stop working.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/Murmur.app"
BIN="$ROOT/.build/$CONFIG/Murmur"
VERSION="0.8.0"

[ -x "$BIN" ] || { echo "Build first: swift build -c $CONFIG"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/Assets/Murmur.icns" "$APP/Contents/Resources/Murmur.icns"

# SwiftPM emits resources as sibling .bundle directories. They travel into
# Contents/Resources for FluidAudio's sake, but the app must never reach them
# through Bundle.module: that accessor looks beside the .app and at a path into
# this machine's .build directory, and fatalErrors elsewhere. Our own font is
# copied in flat and found by hand (see Fonts.register). release.sh proves the
# built app launches with .build hidden.
for b in "$ROOT/.build/$CONFIG"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
done
cp "$ROOT/Sources/Murmur/Resources/BricolageGrotesque.ttf" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Murmur</string>
    <key>CFBundleDisplayName</key><string>Murmur</string>
    <key>CFBundleIdentifier</key><string>com.fintonlabs.murmur</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Murmur</string>
    <key>CFBundleIconFile</key><string>Murmur</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License - Copyright (c) fintonlabs.com</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur transcribes your speech on this Mac. Audio never leaves the device.</string>
</dict>
</plist>
PLIST

# Discover the Developer ID rather than hardcoding it, and fall back to ad-hoc so
# a machine without the certificate still produces a runnable local build.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"

if [ -n "$IDENTITY" ]; then
    echo "Signing as: $IDENTITY"
    codesign --force --options runtime --timestamp \
             --entitlements "$ROOT/Assets/Murmur.entitlements" \
             --sign "$IDENTITY" "$APP"
else
    echo "No Developer ID found — signing ad-hoc (local use only)."
    codesign --force --sign - "$APP"
fi

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "Built $APP"
