#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build/release"
APP_DIR="${PROJECT_DIR}/dist/XDM Test.app"

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/xdm-new-logo.png" "$APP_DIR/Contents/Resources/xdm-new-logo.png"
cp "$PROJECT_DIR/Resources/XDMNew.icns" "$APP_DIR/Contents/Resources/XDMNew.icns"
ditto "$PROJECT_DIR/firefox-extension" "$APP_DIR/Contents/Resources/firefox-extension"
ditto "$PROJECT_DIR/chrome-extension" "$APP_DIR/Contents/Resources/chrome-extension"
cp "$BUILD_DIR/XDMTest" "$APP_DIR/Contents/MacOS/XDMTest"
cp "$BUILD_DIR/XDMNativeHost" "$APP_DIR/Contents/Resources/XDMNativeHost"
chmod 755 "$APP_DIR/Contents/MacOS/XDMTest"
chmod 755 "$APP_DIR/Contents/Resources/XDMNativeHost"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Test app created: $APP_DIR"
