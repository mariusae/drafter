#!/bin/sh
# Builds Drafter.app into build/. `scripts/build-app.sh run` also launches it.
set -e
cd "$(dirname "$0")/.."

swift build -c release
app=build/Drafter.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Drafter" "$app/Contents/MacOS/Drafter"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The icon is drawn by a script, and only redrawn when the script changes.
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  iconset=build/AppIcon.iconset
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app" >/dev/null 2>&1
# Tell Launch Services about the app, so drafter:// links reach it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Drafter 2>/dev/null || true
  open "$app"
fi
