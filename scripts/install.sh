#!/bin/bash
# Builds Procopticon and installs it into /Applications (or $INSTALL_DIR).
#   SIGN_IDENTITY="Apple Development: …"  sign with a certificate (default: ad-hoc)
#   INSTALL_DIR=~/Applications            install somewhere else
#   --no-open                             don't launch after installing
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Procopticon"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME.app"
OPEN_AFTER=1
[[ "${1:-}" == "--no-open" ]] && OPEN_AFTER=0

./scripts/build-app.sh

# Quit a running copy (normal or root instance) so the bundle can be replaced.
if pgrep -f "$APP_NAME.app/Contents/MacOS/Procopticon" >/dev/null; then
    echo "Quitting running ${APP_NAME}…"
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -f "$APP_NAME.app/Contents/MacOS/Procopticon" >/dev/null || break
        sleep 0.25
    done
    # A root ("sudo mode") instance can't be quit by AppleScript from this user.
    if pgrep -f "$APP_NAME.app/Contents/MacOS/Procopticon" >/dev/null; then
        pkill -f "$APP_NAME.app/Contents/MacOS/Procopticon" 2>/dev/null \
            || sudo pkill -f "$APP_NAME.app/Contents/MacOS/Procopticon" || true
    fi
fi

# Use sudo only if the destination isn't writable by the current user.
SUDO=""
if [[ ! -w "$INSTALL_DIR" ]] || { [[ -e "$DEST" ]] && [[ ! -w "$DEST" ]]; }; then
    SUDO="sudo"
fi

echo "Installing to ${DEST}…"
$SUDO rm -rf "$DEST"
$SUDO ditto "build/$APP_NAME.app" "$DEST"

echo "Installed $DEST"
echo "Sudo mode: sudo \"$DEST/Contents/MacOS/Procopticon\""

if [[ $OPEN_AFTER -eq 1 ]]; then
    open "$DEST"
fi
