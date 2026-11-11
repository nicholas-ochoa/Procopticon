#!/bin/bash
# Builds the copy of Procopticon that is handed to other people: a universal build signed with a
# Developer ID certificate, notarized by Apple and stapled, in a disk image. macOS opens it without
# the "Apple could not verify" warning.
#
#   VERSION=1.2.3 ./scripts/release.sh        → build/Procopticon-1.2.3.dmg
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain (Xcode ▸ Settings ▸ Accounts ▸
#     Manage Certificates, or developer.apple.com). SIGN_IDENTITY picks one when there are several.
#   - notarization credentials saved in the keychain under the name in NOTARY_PROFILE:
#       xcrun notarytool store-credentials procopticon-notary \
#           --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#     (an app-specific password comes from account.apple.com ▸ Sign-In and Security; an App Store
#     Connect API key works too: --key, --key-id, --issuer.)
#
#   NOTARIZE=0 stops after signing, for trying the rest of the script out.
#   NOTARY_KEYCHAIN=/path/to.keychain-db is where the credentials are, when not in the login keychain
#     (the Release workflow, .github/workflows/release.yml, keeps them in a keychain of its own).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION, e.g. VERSION=1.0.0 ./scripts/release.sh}"
NOTARY_PROFILE="${NOTARY_PROFILE:-procopticon-notary}"
NOTARIZE="${NOTARIZE:-1}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain. See the top of this script." >&2
    exit 1
fi
echo "Signing as: $SIGN_IDENTITY"

APP="build/Procopticon.app"
DMG="build/Procopticon-$VERSION.dmg"
ZIP="build/Procopticon-$VERSION.zip"

VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" TIMESTAMP=1 UNIVERSAL=1 CONFIG=release VARIANT=release ./scripts/build-app.sh
codesign --verify --strict --deep "$APP"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
        ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
}

# The app first, so that the ticket stapled to it also covers a copy taken out of the disk image
# and opened offline.
if [ "$NOTARIZE" = 1 ]; then
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Procopticon.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Procopticon $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "Not notarized (NOTARIZE=0): macOS will warn about this copy on other Macs."
fi
echo "Built $DMG"
shasum -a 256 "$DMG"
