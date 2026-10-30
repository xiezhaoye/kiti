#!/bin/bash
# Build and package lingo into build/lingo.dmg (drag-to-Applications layout)
set -euo pipefail
cd "$(dirname "$0")"
LINGO_SKIP_INSTALL=1 ./build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/lingo.dmg
mkdir -p "$STAGE"
cp -R build/lingo.app "$STAGE/lingo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname lingo -srcfolder "$STAGE" -ov -format UDZO build/lingo.dmg >/dev/null
rm -rf "$STAGE"
echo "Packaged build/lingo.dmg"
