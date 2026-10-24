#!/bin/sh
# Builds dist/Twinfold.app (universal when the toolchain allows) and dist/twinfold (CLI).
set -e
cd "$(dirname "$0")/.."
VERSION=$(grep 'let version' Sources/twinfold/main.swift | sed 's/.*"\(.*\)".*/\1/')
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product TwinfoldApp 2>/dev/null || ARCHS=""
swift build -c release $ARCHS --product TwinfoldApp
swift build -c release $ARCHS --product twinfold
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=dist/Twinfold.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TwinfoldApp" "$APP/Contents/MacOS/Twinfold"
cp "$BIN/twinfold" dist/twinfold
cp -R Sources/TwinfoldApp/Fonts "$APP/Contents/Resources/Fonts"

# Icon: render the SwiftUI icon, then build every size iconutil wants.
ICON=.build/icon && rm -rf $ICON && mkdir -p $ICON/Twinfold.iconset
TWINFOLD_SNAPSHOT=$ICON "$BIN/TwinfoldApp" >/dev/null 2>&1 || true
for s in 16 32 128 256 512; do
  sips -z $s $s $ICON/icon-1024.png --out $ICON/Twinfold.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s * 2)); sips -z $d $d $ICON/icon-1024.png --out $ICON/Twinfold.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICON/Twinfold.iconset -o "$APP/Contents/Resources/Twinfold.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Twinfold</string>
  <key>CFBundleDisplayName</key><string>Twinfold</string>
  <key>CFBundleIdentifier</key><string>app.twinfold.Twinfold</string>
  <key>CFBundleExecutable</key><string>Twinfold</string>
  <key>CFBundleIconFile</key><string>Twinfold</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

if ! grep -q 'mode: Mode = .live' Sources/TwinfoldCore/Licensing.swift; then
  echo "warning: the app is using the TEST store (Dodo test mode); set the live product in Licensing.swift before release" >&2
fi

codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"
rm -rf dist/zip && mkdir -p dist/zip && ditto dist/Twinfold.app dist/zip/Twinfold.app && cp packaging/READ-ME-FIRST.txt dist/zip/
(cd dist/zip && rm -f ../Twinfold-$VERSION.zip && ditto -c -k . ../Twinfold-$VERSION.zip)  # the app plus how to open it the first time
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Twinfold"))"
