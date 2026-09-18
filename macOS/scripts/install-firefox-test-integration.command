#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/XDM New.app}"
HOST_EXECUTABLE="$APP_DIR/Contents/Resources/XDMNativeHost"
MANIFEST_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/org.xdm.test.json"

if [[ ! -x "$HOST_EXECUTABLE" ]]; then
  echo "Build the test app first: $PROJECT_DIR/scripts/build-macos.command"
  exit 66
fi
if [[ -e "$MANIFEST_PATH" ]]; then
  echo "Refusing to overwrite existing Firefox native-host manifest: $MANIFEST_PATH"
  exit 65
fi

mkdir -p "$MANIFEST_DIR"
cp "$PROJECT_DIR/Resources/org.xdm.test.native-host.json" "$MANIFEST_PATH"
plutil -replace path -string "$HOST_EXECUTABLE" "$MANIFEST_PATH"
chmod 600 "$MANIFEST_PATH"

echo "Firefox native host installed: $MANIFEST_PATH"
echo "Load the temporary extension from: $PROJECT_DIR/firefox-extension/manifest.json"
