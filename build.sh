#!/usr/bin/env bash
# Builds "build/Image Viewer.app" (universal: Apple Silicon + Intel) and a zip for copying to other Macs.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Image Viewer"
EXECUTABLE="ImageViewer"
VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/$APP_NAME.app"

binaries=()
for arch in $ARCHS; do
    echo "==> Compiling for $arch"
    swift build -c release --arch "$arch"
    binaries+=(".build/$arch-apple-macosx/release/$EXECUTABLE")
done

if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Drawing app icon"
    iconset="$(mktemp -d)/AppIcon.iconset"
    swift scripts/make_icon.swift "$iconset"
    iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with a stable identity when this Mac has one (Developer ID, else Apple Development), so
# macOS privacy permissions (Desktop, Documents, Full Disk Access…) survive rebuilds. An ad-hoc
# signature is tied to the exact binary, so every rebuild looks like a new app and is asked again.
# Override with SIGN_IDENTITY="<name or SHA-1>"; SIGN_IDENTITY=- forces ad-hoc. Not notarized either way.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # (`|| true`: finding no such certificate is normal, not an error under `set -e`/pipefail)
    SIGN_IDENTITY="$(echo "$identities" | grep '"Developer ID Application' | head -1 | awk '{print $2}' || true)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$identities" | grep '"Apple Development' | head -1 | awk '{print $2}' || true)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "    Signed: ad-hoc (macOS will ask for folder permissions again after each rebuild)"
else
    echo "    Signed: $(codesign -dvv "$APP" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2)"
fi

rm -f "build/ImageViewer.zip"
ditto -c -k --keepParent "$APP" "build/ImageViewer.zip"

echo "==> Done: $APP"
echo "    Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
echo "    Zip for other Macs: build/ImageViewer.zip"
