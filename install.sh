#!/usr/bin/env bash
# Installs Image Viewer into /Applications.
#   ./install.sh                       build from source, then install
#   ./install.sh path/to/ImageViewer.zip   install a prebuilt zip (e.g. copied from another Mac)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Image Viewer"
DEST="/Applications/$APP_NAME.app"

if [ $# -ge 1 ]; then
    tmp="$(mktemp -d)"
    ditto -x -k "$1" "$tmp"
    SOURCE="$tmp/$APP_NAME.app"
else
    ./build.sh
    SOURCE="build/$APP_NAME.app"
fi

osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"
# Files copied via AirDrop/download are quarantined; this app isn't notarized, so clear the flag.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# Register so "Open With ▸ Image Viewer" shows up in Finder.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

echo "Installed to $DEST"
