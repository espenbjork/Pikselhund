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

echo "==> Sjekker tegningen"
python3 - "$HERE/Art/pikselhund.txt" <<'SJEKK'
import re, sys
tekst = open(sys.argv[1], encoding="utf-8").read()
feil = [(n, len(b.rstrip("\n").split("\n")))
        for n, b in re.findall(r"ramme (\S+)\n((?:  [^\n]*\n)+)", tekst)
        if len(b.rstrip("\n").split("\n")) != 32]
feil += [(n, "skjev rad") for n, b in re.findall(r"ramme (\S+)\n((?:  [^\n]*\n)+)", tekst)
         if any(len(r.strip()) != 32 for r in b.rstrip("\n").split("\n"))]
if feil:
    for navn, hva in feil:
        print(f"   FEIL: ramme '{navn}': {hva}")
    sys.exit(1)
print(f"   {len(re.findall(r'^ramme ', tekst, re.M))} rammer, alle 32x32")
SJEKK

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

# Det nye tegnesettet klippes ut av arkene i Art/kilde hver gang, så appen
# aldri kan få en gammel utgave. Mangler Pillow, bygger vi uten, og menyvalget
# «Ny tegning» blir grået ut.
if python3 -c "import PIL" 2>/dev/null; then
  echo "==> Klipper figurene"
  python3 "$HERE/tools/klipp-sprites.py" >/dev/null
  rm -rf "$RES/sprites"
  mkdir -p "$RES/sprites"
  cp "$HERE"/Art/sprites/*.png "$RES/sprites/" 2>/dev/null || true
  rm -f "$RES/sprites/oversikt.png"
else
  echo "==> Uten Pillow, hopper over det nye tegnesettet"
fi

if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"
else
  echo "   (AppIcon.icns mangler, lag det med tools/lag-ikon.py)"
fi

echo "==> Signerer (ad-hoc)"
codesign --force --sign - --identifier net.betulae.pikselhund "$APP"

echo "==> Ferdig: $APP"
