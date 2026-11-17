#!/bin/bash
# Builds Lowkeys.app with nothing but the Xcode Command Line Tools.
#
#   ./build.sh [out_dir] [version]      default: ./build, 0.0.0
#
# The app is built on the Mac that will run it. A locally built app carries
# no quarantine flag, so Gatekeeper has nothing to block and nobody needs a
# paid developer account.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SRC/build}"
VERSION="${2:-0.0.0}"
APP="$OUT/Lowkeys.app"
NEW="$OUT/Lowkeys.app.new"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 3
fi

rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"

swiftc -O -o "$NEW/Contents/MacOS/Lowkeys" "$SRC/Lowkeys.swift"

cp -R "$SRC/web" "$SRC/fonts" "$SRC/sounds" "$NEW/Contents/Resources/"

cat > "$NEW/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lowkeys</string>
  <key>CFBundleDisplayName</key><string>Lowkeys</string>
  <key>CFBundleIdentifier</key><string>com.stupendiff.lowkeys</string>
  <key>CFBundleExecutable</key><string>Lowkeys</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --deep -s - "$NEW" 2>/dev/null || echo "  (ad-hoc signing skipped)"

# Swap the finished app in, so a running copy is never half replaced.
rm -rf "$APP"
mv "$NEW" "$APP"
echo "$APP"
