#!/bin/zsh
# Builds JAGBA.app (Apple Silicon + Intel) into ./build and zips it for sharing.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/JAGBA.app
VERSION=2.0.1
# The GitHub repository the app checks for new releases ("owner/name").
REPO="${JAGBA_REPO:-Kreativetrybe/jagba}"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/JAGBA-$arch"
done
lipo -create build/JAGBA-arm64 build/JAGBA-x86_64 -output "$APP/Contents/MacOS/JAGBA"
rm build/JAGBA-arm64 build/JAGBA-x86_64

[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"   # Courier Prime + font licenses

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JAGBA</string>
  <key>CFBundleDisplayName</key><string>JAGBA</string>
  <key>CFBundleExecutable</key><string>JAGBA</string>
  <key>CFBundleIdentifier</key><string>app.jagba.JAGBA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>JAGBARepository</key><string>$REPO</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>JAGBA transcribes the videos you choose on this Mac.</string>
</dict>
</plist>
PLIST

# Sign with the "JAGBA Signing" certificate if this Mac has it, so macOS
# permissions (Full Disk Access) survive rebuilds. Otherwise sign ad hoc,
# which gives every build a new identity.
SIGN_ID="JAGBA Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
  echo "Signed with $SIGN_ID"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc (no \"$SIGN_ID\" certificate found)"
fi
(cd build && ditto -c -k --keepParent JAGBA.app "JAGBA-$VERSION.zip")
echo "Built $APP and build/JAGBA-$VERSION.zip"
