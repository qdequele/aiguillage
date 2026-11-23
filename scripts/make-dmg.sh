#!/bin/bash
# Builds Aiguillage.app (menu-bar agent + embedded daemon) and a drag-to-install .dmg.
# No Xcode and no Apple Developer account needed: the app is ad-hoc signed; Gatekeeper will
# require a right-click > Open on first launch (documented in the DMG background text).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Aiguillage"
BUNDLE_ID="com.qdequelen.aiguillage"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

echo "==> swift build -c release"
swift build -c release >/dev/null

BIN_DIR="$ROOT/.build/release"
[ -x "$BIN_DIR/aiguillage" ] || { echo "missing daemon binary"; exit 1; }
[ -x "$BIN_DIR/aiguillage-menubar" ] || { echo "missing menubar binary"; exit 1; }

echo "==> assembling $APP_NAME.app ($VERSION, build $BUILD)"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Menu-bar app is the bundle executable; the daemon sits next to it (resolveDaemonBinary()
# looks for a sibling named "aiguillage"). The executable is named "AiguillageAgent" — NOT
# "Aiguillage" — because the filesystem is case-insensitive, so "Aiguillage" and "aiguillage"
# would be the same file and one binary would clobber the other.
EXE="${APP_NAME}Agent"
cp "$BIN_DIR/aiguillage-menubar" "$APP/Contents/MacOS/$EXE"
cp "$BIN_DIR/aiguillage"         "$APP/Contents/MacOS/aiguillage"
chmod +x "$APP/Contents/MacOS/$EXE" "$APP/Contents/MacOS/aiguillage"

# Icon: render 1024 PNG, expand to an iconset, pack to .icns.
echo "==> icon"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/appicon.swift" "$DIST/icon_1024.png" >/dev/null
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s "$DIST/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
# Retina (@2x) variants expected by iconutil.
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}Agent</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Aiguillage</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc codesign"
# Sign the embedded daemon first, then the app bundle (deep).
codesign --force --sign - "$APP/Contents/MacOS/aiguillage" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> building $APP_NAME.dmg"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<'TXT'
Installing Aiguillage
=====================
1. Drag Aiguillage.app into the Applications folder (next to this file).
2. First launch: right-click the app > Open (app not signed by Apple), then
   "Open" in the dialog. Once only.
3. The icon (a railway switch) appears in the menu bar, top right.
4. "Start the daemon…" asks for the admin password (network routing requires
   root). The daemon then runs in the background.

Tip: to avoid the password at every startup, you can install the daemon as a
launchd service — see the README.
TXT

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$ICONSET" "$DIST/icon_1024.png"

echo
echo "OK -> $DMG"
ls -lh "$DMG" | awk '{print $5, $NF}'
