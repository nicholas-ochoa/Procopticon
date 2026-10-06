#!/bin/bash
# Builds "Process Informer.app" into ./build.
#   CONFIG=debug|release (default release)
#   SIGN_IDENTITY="Apple Development: …" to sign with a certificate (default: ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# VARIANT=dev builds "Process Informer Dev" with its own bundle id, executable name and preferences,
# so a test build can run next to the installed app without sharing settings or window state.
VARIANT="${VARIANT:-release}"
if [ "$VARIANT" = dev ]; then
    APP_NAME="Process Informer Dev"
    EXEC_NAME="ProcessInformerDev"
    BUNDLE_ID="${BUNDLE_ID:-com.processinformer.ProcessInformer.dev}"
else
    APP_NAME="Process Informer"
    EXEC_NAME="ProcessInformer"
    BUNDLE_ID="${BUNDLE_ID:-com.processinformer.ProcessInformer}"
fi
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="build/${APP_NAME}.app"

swift build -c "$CONFIG" --product ProcessInformer
swift build -c "$CONFIG" --product informer-helper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/ProcessInformer" "$OUT/Contents/MacOS/$EXEC_NAME"
cp "$BIN/informer-helper" "$OUT/Contents/MacOS/informer-helper"

# Icon
ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    rm -rf "$ICONSET"
    swift scripts/make-icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
    rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Process Informer — a process explorer for macOS.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier "${BUNDLE_ID}.helper" "$OUT/Contents/MacOS/informer-helper"
codesign --force --sign "$IDENTITY" --timestamp=none "$OUT"
echo "Built $OUT"
