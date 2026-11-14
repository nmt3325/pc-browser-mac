#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${APP_VERSION:-0.2.0-beta.2}
BUILD=${APP_BUILD:-14}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]
SHORT_VERSION=${VERSION%%-*}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
swift build -c "$CONFIG" --jobs 2
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP="$PWD/build/PC Browser Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/PCBrowserMac" "$APP/Contents/MacOS/PCBrowserMac"
clang -O2 -Wall -Wextra -ISources/PCRawIO/include Helpers/RawReader.c Sources/PCRawIO/raw_io.c -framework DiskArbitration -framework CoreFoundation -o "$APP/Contents/MacOS/PCBrowserRawReader"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.salvare.pcbrowser-mac</string>
<key>CFBundleName</key><string>PC Browser Mac</string>
<key>CFBundleDisplayName</key><string>PC Browser Mac</string>
<key>CFBundleExecutable</key><string>PCBrowserMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleGetInfoString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>SD Card Image</string>
<key>CFBundleTypeExtensions</key><array><string>img</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
</dict><dict>
<key>CFBundleTypeName</key><string>PC Browser Windows Backup</string>
<key>CFBundleTypeExtensions</key><array><string>bak</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
</dict><dict>
<key>CFBundleTypeName</key><string>PC Browser Mac Selected Recording Backup</string>
<key>CFBundleTypeExtensions</key><array><string>pcbbackup</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string><key>LSTypeIsPackage</key><true/>
</dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'APP_READY: %s\n' "$APP"
