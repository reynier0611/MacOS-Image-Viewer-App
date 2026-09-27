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

# Ad-hoc signature: required to run on Apple Silicon. Not notarized (see README for other Macs).
codesign --force --sign - "$APP"

rm -f "build/ImageViewer.zip"
ditto -c -k --keepParent "$APP" "build/ImageViewer.zip"

echo "==> Done: $APP"
echo "    Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
echo "    Zip for other Macs: build/ImageViewer.zip"
