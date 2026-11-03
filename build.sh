#!/bin/bash
set -e

APP_NAME="KeepMacAudioAlive"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Creating app bundle structure..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> Generating AppIcon.icns from asset image..."
ICONSET_DIR="/tmp/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16     KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null 2>&1
sips -z 32 32     KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null 2>&1
sips -z 32 32     KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null 2>&1
sips -z 64 64     KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null 2>&1
sips -z 128 128   KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null 2>&1
sips -z 256 256   KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null 2>&1
sips -z 256 256   KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null 2>&1
sips -z 512 512   KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null 2>&1
sips -z 512 512   KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null 2>&1
sips -z 1024 1024 KeepMacAudioAlive/Assets.xcassets/AppIcon.appiconset/finalIcon3.png --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null 2>&1
iconutil -c icns "${ICONSET_DIR}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

echo "==> Compiling Swift sources..."
mkdir -p /tmp/mcache
swiftc -parse-as-library \
       -module-cache-path /tmp/mcache \
       -target arm64-apple-macos14.0 \
       KeepMacAudioAlive/KeepAudioAliveApp.swift \
       -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "==> Generating Info.plist..."
cat << 'PLIST' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KeepMacAudioAlive</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.openmac.KeepAudioAlive</string>
    <key>CFBundleName</key>
    <string>KeepMacAudioAlive</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>1.6.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Code-signing app bundle (ad-hoc)..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Build successful! You can test or launch it with:"
echo "    open ${APP_BUNDLE}"
