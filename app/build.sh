#!/bin/bash
# Build and sign lingo.app into ./build/lingo.app; optionally install.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/lingo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/kiti "$APP/Contents/MacOS/kiti"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICON_SOURCE=Resources/dock-icon.png
if [ ! -f "$ICON_SOURCE" ]; then ICON_SOURCE=Resources/logo.png; fi
if [ -f "$ICON_SOURCE" ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$ICON_SOURCE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SOURCE" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  cp Resources/logo.png "$APP/Contents/Resources/logo.png"
  cp Resources/logo-bird.png "$APP/Contents/Resources/logo-bird.png"
fi
cp Resources/dock-icon.png "$APP/Contents/Resources/dock-icon.png"
cp Resources/menubar.png Resources/menubar@2x.png "$APP/Contents/Resources/"
cp Resources/ecdict.tsv "$APP/Contents/Resources/ecdict.tsv"
IDENT=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
codesign --force --deep --sign "${IDENT:--}" --identifier app.kiti.mac "$APP"
if [ "${LINGO_SKIP_INSTALL:-0}" != 1 ]; then
  mkdir -p /Applications
  if [ -e /Applications/lingo.app ]; then
    echo "请先将现有 /Applications/lingo.app 移至废纸篓，再运行安装。" >&2
    exit 1
  fi
  ditto "$APP" /Applications/lingo.app
  echo "Installed /Applications/lingo.app"
fi
echo "Built $APP (signed: ${IDENT:-ad-hoc})"
