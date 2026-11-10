#!/bin/bash
# Builds "Procopticon.app" into ./build.
#   CONFIG=debug|release (default release)
#   SIGN_IDENTITY="Apple Development: …" to sign with a certificate (default: ad-hoc)
#   UNIVERSAL=1 builds for Apple silicon and Intel (default: this Mac's architecture)
#   VERSION=1.2.3 sets the version shown in About (default 1.0.0)
# scripts/release.sh builds, signs and notarizes a copy to hand to other people.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# VARIANT=dev builds "Procopticon Dev" with its own bundle id, executable name and preferences,
# so a test build can run next to the installed app without sharing settings or window state.
VARIANT="${VARIANT:-release}"
if [ "$VARIANT" = dev ]; then
    APP_NAME="Procopticon Dev"
    EXEC_NAME="ProcopticonDev"
    BUNDLE_ID="${BUNDLE_ID:-com.procopticon.Procopticon.dev}"
else
    APP_NAME="Procopticon"
    EXEC_NAME="Procopticon"
    BUNDLE_ID="${BUNDLE_ID:-com.procopticon.Procopticon}"
fi
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="build/${APP_NAME}.app"

ARCHS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product Procopticon
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product procopticon-helper
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/Procopticon" "$OUT/Contents/MacOS/$EXEC_NAME"
cp "$BIN/procopticon-helper" "$OUT/Contents/MacOS/procopticon-helper"

# Icon: actool compiles the Icon Composer document into Assets.car (what macOS draws, in every
# appearance) and AppIcon.icns (for anything that only reads CFBundleIconFile). Needs Xcode.
# Paths are absolute: actool hands the work to a daemon that resolves relative ones against its own
# working directory, which is wherever actool first ran.
ICON_SRC="$PWD/Resources/AppIcon.icon"
ICON_OUT="$PWD/build/icon"
if [ ! -f "$ICON_OUT/Assets.car" ] || [ -n "$(find "$ICON_SRC" -newer "$ICON_OUT/Assets.car")" ]; then
    rm -rf "$ICON_OUT"
    mkdir -p "$ICON_OUT"
    if ! xcrun actool "$ICON_SRC" --compile "$ICON_OUT" --app-icon AppIcon \
            --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$ICON_OUT/partial.plist" \
            --errors --warnings --output-format human-readable-text >"$ICON_OUT/actool.log" 2>&1 \
        || [ ! -f "$ICON_OUT/Assets.car" ]; then
        cat "$ICON_OUT/actool.log" >&2
        rm -f "$ICON_OUT/Assets.car"
        exit 1
    fi
fi
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$OUT/Contents/Resources/"

# The licenses of the app and of QuickJS-ng, which is compiled into it. The MIT license asks for
# them in every copy; About Procopticon shows them from here.
mkdir -p "$OUT/Contents/Resources/Licenses"
cp LICENSE "$OUT/Contents/Resources/Licenses/Procopticon.txt"
cp Sources/CQuickJS/quickjs/LICENSE "$OUT/Contents/Resources/Licenses/QuickJS-ng.txt"

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
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key><string>Procopticon asks applications to quit when you choose Quit Application.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Nicholas Ochoa. MIT License.</string>
</dict>
</plist>
PLIST

# The hardened runtime keeps other code out of the app (DYLD_INSERT_LIBRARIES, unsigned libraries),
# which matters because the root helper trusts whatever the app process asks of it. The one exception
# the app needs is sending Apple events (quitting an application).
ENTITLEMENTS="build/Procopticon.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
# Notarization wants Apple's timestamp on a Developer ID signature; other builds do without the
# round trip to Apple's server.
TIMESTAMP="--timestamp=none"
case "$IDENTITY" in "Developer ID"*) TIMESTAMP="--timestamp" ;; esac
codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime --identifier "${BUNDLE_ID}.helper" \
    "$OUT/Contents/MacOS/procopticon-helper"
codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime --entitlements "$ENTITLEMENTS" "$OUT"
echo "Built $OUT"
