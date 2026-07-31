#!/bin/bash
# Build Musical Trainer.app.
#
# SwiftUI runs from a bare SPM executable, but macOS treats an unbundled binary as a
# background process: no dock icon, no menu bar, and no Info.plist — which means no way to
# request microphone access for calibration. Wrapping the binary in a minimal .app fixes all
# three without needing an Xcode project.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="Musical Trainer.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product MusicalTrainer

BIN=".build/$CONFIG/MusicalTrainer"
[ -f "$BIN" ] || { echo "Build produced no binary at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MusicalTrainer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Musical Trainer</string>
    <key>CFBundleDisplayName</key>       <string>Musical Trainer</string>
    <key>CFBundleIdentifier</key>        <string>com.duvalanalytics.musicaltrainer</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>MusicalTrainer</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Only calibration records audio; takes need output and MIDI alone. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Musical Trainer measures your audio output latency by recording its own test tone.</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS keeps the same TCC identity between builds; without it the
# microphone permission is re-requested every time the binary changes.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing unavailable"

echo "Built $APP"
echo "Run it with:  open '$APP'"
