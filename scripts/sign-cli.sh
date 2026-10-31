#!/bin/bash
# Builds the release `ghosttrace` and signs it with this Mac's Apple Development identity for the GhostTrace team.
# The recorder under launchd answers only XPC clients signed by the same team (ADR 0005); an unsigned CLI reaches only a
# terminal recorder (GHOSTTRACE_HOME + socket). Usage: scripts/sign-cli.sh   (prints the signed binary's path)
set -euo pipefail
TEAM=5PCPH987YL
cd "$(dirname "$0")/.."
swift build -c release --product ghosttrace >&2
BIN="$(swift build -c release --product ghosttrace --show-bin-path)/ghosttrace"
# With several identities installed, take the one whose signature carries the team.
for hash in $(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2 }'); do
  codesign --force --sign "$hash" --identifier com.amoghkhairate.GhostTrace.cli "$BIN" >&2
  info=$(codesign -dv "$BIN" 2>&1)
  if [[ $info == *"TeamIdentifier=$TEAM"* ]]; then echo "$BIN"; exit 0; fi
done
echo "No Apple Development identity for team $TEAM. In Xcode: Settings > Accounts > Manage Certificates > + > Apple Development." >&2
exit 1
