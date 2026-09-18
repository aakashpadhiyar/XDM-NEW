#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/XDM New.app"
TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" ]]; then
  echo "Usage: open install-test-app.command --args /path/to/test-applications-folder"
  echo "Example: open install-test-app.command --args \"$PWD/test-applications\""
  exit 64
fi

"$SCRIPT_DIR/build-macos.command"
mkdir -p "$TARGET_DIR"

if [[ -e "$TARGET_DIR/XDM New.app" ]]; then
  echo "Refusing to overwrite existing test app: $TARGET_DIR/XDM New.app"
  echo "Choose an empty folder or move the previous test app first."
  exit 65
fi

ditto "$APP_DIR" "$TARGET_DIR/XDM New.app"
xattr -cr "$TARGET_DIR/XDM New.app"
codesign --force --deep --sign - "$TARGET_DIR/XDM New.app"
codesign --verify --deep "$TARGET_DIR/XDM New.app"
open "$TARGET_DIR/XDM New.app"
echo "Installed test app: $TARGET_DIR/XDM New.app"
