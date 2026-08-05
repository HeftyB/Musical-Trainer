#!/bin/bash
# Build a release artifact: the .app, the CLI, and a checksum.
#
#   ./scripts/package-release.sh            version from `git describe`
#   ./scripts/package-release.sh v0.2.0     explicit version
#
# Output lands in dist/. macOS only — the app needs AVFoundation and CoreMIDI, so this cannot
# run in the Linux verification container (see .woodpecker/test.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
    echo "package-release.sh needs macOS: the app links AVFoundation and CoreMIDI." >&2
    exit 1
fi

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
DIST="dist"
NAME="MusicalTrainer-$VERSION"

echo "Packaging $NAME"
rm -rf "$DIST"
mkdir -p "$DIST"

# The gate runs first. A release that was never verified is not a release.
./scripts/check.sh

swift build -c release
./build-app.sh release

# Ship the CLI alongside the app: calibration and the diagnostics are console-only.
cp ".build/release/TimingSpike" "$DIST/TimingSpike"
cp -R "Musical Trainer.app" "$DIST/"

cat > "$DIST/VERSION.txt" <<EOF
Musical Trainer $VERSION
built    $(date -u '+%Y-%m-%dT%H:%M:%SZ')
commit   $(git rev-parse HEAD 2>/dev/null || echo unknown)
swift    $(swift --version 2>&1 | head -1)
macOS    $(sw_vers -productVersion)
EOF

( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "Musical Trainer.app" "$NAME.zip" )
( cd "$DIST" && shasum -a 256 "$NAME.zip" TimingSpike > "$NAME.sha256" )
rm -rf "$DIST/Musical Trainer.app"

echo
echo "Artifacts in $DIST/:"
ls -1 "$DIST"
