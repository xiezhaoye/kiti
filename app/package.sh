#!/bin/bash
# Build and package kiti into build/kiti.dmg (drag-to-Applications layout)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/kiti.dmg
mkdir -p "$STAGE"
cp -R build/kiti.app "$STAGE/kiti.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname kiti -srcfolder "$STAGE" -ov -format UDZO build/kiti.dmg >/dev/null
rm -rf "$STAGE"
echo "Packaged build/kiti.dmg"
