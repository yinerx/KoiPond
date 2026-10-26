#!/bin/sh
# Builds KoiPond.app (with the screen saver inside) and KoiPond.saver as universal binaries, then zips them.
# usage: scripts/bundle.sh <version>      (macOS only; output in dist/)
set -eu
VERSION=${1:-0.0.0-dev}
BUILD=${BUILD_NUMBER:-1}
REPO=${KP_UPDATE_REPO:-yinerx/KoiPond}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product KoiPond
swift build -c release $ARCHS --product PondSaver
BIN=$(swift build -c release $ARCHS --show-bin-path)

rm -rf dist && mkdir -p dist
APP=dist/KoiPond.app
SAVER=dist/KoiPond.saver

# — screen saver bundle: the dynamic library is the bundle executable —
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp "$BIN/libPondSaver.dylib" "$SAVER/Contents/MacOS/KoiPond"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" scripts/Info-Saver.plist > "$SAVER/Contents/Info.plist"

# — app bundle —
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KoiPond" "$APP/Contents/MacOS/KoiPond"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" -e "s#__REPO__#$REPO#g" scripts/Info-App.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f scripts/AppIcon.icns ]; then cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp -R "$SAVER" "$APP/Contents/Resources/KoiPond.saver"

# ad-hoc signatures (no Developer ID): inner bundle first
codesign --force --sign - "$APP/Contents/Resources/KoiPond.saver"
codesign --force --sign - "$SAVER"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/KoiPond"
lipo -info "$SAVER/Contents/MacOS/KoiPond"

(cd dist && ditto -c -k --keepParent KoiPond.app "KoiPond-$VERSION.zip")
(cd dist && ditto -c -k --keepParent KoiPond.saver "KoiPond-Saver-$VERSION.zip")
ls -l dist
