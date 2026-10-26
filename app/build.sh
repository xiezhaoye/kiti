#!/bin/bash
# Build kiti.app (ad-hoc signed) into ./build/kiti.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/kiti.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/kiti "$APP/Contents/MacOS/kiti"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/logo.png ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s Resources/logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  cp Resources/logo.png "$APP/Contents/Resources/logo.png"
  cp Resources/logo-bird.png "$APP/Contents/Resources/logo-bird.png"
fi
cp Resources/menubar.png Resources/menubar@2x.png "$APP/Contents/Resources/"
cp Resources/ecdict.tsv "$APP/Contents/Resources/ecdict.tsv"
IDENT=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
codesign --force --deep --sign "${IDENT:--}" --identifier app.kiti.mac "$APP"
mkdir -p /Applications
rm -rf /Applications/kiti.app
cp -R "$APP" /Applications/kiti.app
echo "Built $APP (signed: ${IDENT:-ad-hoc}); installed /Applications/kiti.app"
