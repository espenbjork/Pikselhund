#!/bin/bash
# Bygger Pikselhund.app fra Swift-kildene. Krever bare Command Line Tools.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APPNAME="Pikselhund"
OUT="$HERE/build"
APP="$OUT/$APPNAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> Rydder"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Kompilerer Swift"
swiftc -O -swift-version 5 -parse-as-library \
  -framework AppKit -framework ServiceManagement \
  -o "$MACOS/$APPNAME" \
  "$HERE/Sources/"*.swift

echo "==> Skriver Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>nb</string>
  <key>CFBundleName</key><string>Pikselhund</string>
  <key>CFBundleDisplayName</key><string>Pikselhund</string>
  <key>CFBundleIdentifier</key><string>net.betulae.pikselhund</string>
  <key>CFBundleExecutable</key><string>Pikselhund</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Kopierer tegningen"
cp "$HERE/Art/pikselhund.txt" "$RES/pikselhund.txt"

if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"
else
  echo "   (AppIcon.icns mangler, lag det med tools/lag-ikon.py)"
fi

echo "==> Signerer (ad-hoc)"
codesign --force --sign - --identifier net.betulae.pikselhund "$APP"

echo "==> Ferdig: $APP"
