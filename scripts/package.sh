#!/bin/bash
# Builds the Release app and the signed CLI, checks both signatures, and zips them into dist/GhostTrace-<version>.zip.
# Signing is Apple Development (team 5PCPH987YL), and the zip isn't notarized: that needs a Developer ID Application certificate
# (paid Apple Developer Program), which this team doesn't have. Gatekeeper on another Mac refuses it after download (README, Packaging).
# Usage: scripts/package.sh
set -euo pipefail
TEAM=5PCPH987YL
cd "$(dirname "$0")/.."
xcodebuild -project App/GhostTrace.xcodeproj -scheme GhostTraceApp -configuration Release -derivedDataPath .build/xcode build -quiet >&2
APP=.build/xcode/Build/Products/Release/GhostTrace.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
CLI=$(scripts/sign-cli.sh)
for path in "$APP" "$APP/Contents/MacOS/RecorderAgent" "$CLI"; do
  [[ -e $path ]] || { echo "Missing $path" >&2; exit 1; }
  codesign --verify --strict "$path"
  [[ $(codesign -dv "$path" 2>&1) == *"TeamIdentifier=$TEAM"* ]] || { echo "$path isn't signed by team $TEAM" >&2; exit 1; }
done
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/GhostTrace" dist
ditto "$APP" "$STAGE/GhostTrace/GhostTrace.app"
cp "$CLI" "$STAGE/GhostTrace/ghosttrace"
cp README.md docs/privacy.md docs/troubleshooting.md "$STAGE/GhostTrace/"
OUT="dist/GhostTrace-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$STAGE/GhostTrace" "$OUT"
echo "$OUT"
