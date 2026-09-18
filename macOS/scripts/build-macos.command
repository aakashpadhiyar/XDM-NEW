#!/bin/zsh
# Build one locally signed macOS test package without touching source files.
# By default, previous generated test artifacts in macOS/dist are replaced only
# after a new package has compiled, signed, and passed archive verification.

set -euo pipefail
setopt NULL_GLOB

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:t}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RESOURCES_DIR="${PROJECT_DIR}/Resources"
BUILD_DIR="${PROJECT_DIR}/.build/release"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="XDM New.app"
DIST_APP="${DIST_DIR}/${APP_NAME}"
KEEP_OLD=false

usage() {
  print "Usage: ${SCRIPT_NAME} [--keep-old]"
  print "  --keep-old  Preserve prior generated test artifacts in macOS/dist."
}

case "${1:-}" in
  "") ;;
  --keep-old) KEEP_OLD=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 64 ;;
esac

require_path() {
  if [[ ! -e "$1" ]]; then
    print -u2 "Missing required build input: $1"
    exit 66
  fi
}

clean_generated_dist() {
  local artifact
  local -a artifacts

  artifacts=(
    "${DIST_DIR}/.DS_Store"
    "${DIST_DIR}/XDM Test.app"
    "${DIST_DIR}/XDM New.app"
    "${DIST_DIR}/XDM New Browser Monitoring Test.app"
  )
  artifacts+=("${DIST_DIR}"/XDM-New-macOS-*-test.zip(N))

  for artifact in "${artifacts[@]}"; do
    [[ -e "$artifact" ]] || continue
    case "$artifact" in
      "${DIST_DIR}"/*) ;;
      *) print -u2 "Refusing to remove an unexpected path: $artifact"; exit 70 ;;
    esac
    print "Removing previous generated artifact: ${artifact:t}"
    /bin/rm -rf "$artifact"
  done
}

require_path "${RESOURCES_DIR}/Info.plist"
require_path "${RESOURCES_DIR}/xdm-new-logo.png"
require_path "${RESOURCES_DIR}/XDMNew.icns"
require_path "${PROJECT_DIR}/firefox-extension"
require_path "${PROJECT_DIR}/chrome-extension"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${RESOURCES_DIR}/Info.plist")
ARCHIVE_NAME="XDM-New-macOS-${VERSION}-test.zip"

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xdm-new-build.XXXXXX")
STAGE_APP="${STAGE_DIR}/${APP_NAME}"
STAGE_ARCHIVE="${STAGE_DIR}/${ARCHIVE_NAME}"
cleanup_stage() {
  /bin/rm -rf "$STAGE_DIR"
}
trap cleanup_stage EXIT

print "Building XDM New ${VERSION} (release configuration)…"
cd "$PROJECT_DIR"
swift build -c release

require_path "${BUILD_DIR}/XDMTest"
require_path "${BUILD_DIR}/XDMNativeHost"

print "Assembling and signing a clean staging app…"
mkdir -p "${STAGE_APP}/Contents/MacOS" "${STAGE_APP}/Contents/Resources"
cp "${RESOURCES_DIR}/Info.plist" "${STAGE_APP}/Contents/Info.plist"
cp "${RESOURCES_DIR}/xdm-new-logo.png" "${STAGE_APP}/Contents/Resources/xdm-new-logo.png"
cp "${RESOURCES_DIR}/XDMNew.icns" "${STAGE_APP}/Contents/Resources/XDMNew.icns"
ditto "${PROJECT_DIR}/firefox-extension" "${STAGE_APP}/Contents/Resources/firefox-extension"
ditto "${PROJECT_DIR}/chrome-extension" "${STAGE_APP}/Contents/Resources/chrome-extension"
cp "${BUILD_DIR}/XDMTest" "${STAGE_APP}/Contents/MacOS/XDMTest"
cp "${BUILD_DIR}/XDMNativeHost" "${STAGE_APP}/Contents/Resources/XDMNativeHost"
chmod 755 "${STAGE_APP}/Contents/MacOS/XDMTest" "${STAGE_APP}/Contents/Resources/XDMNativeHost"

# Build outside the synced workspace: Finder/File Provider metadata there can
# invalidate an otherwise valid ad-hoc signature.
xattr -cr "${STAGE_APP}"
codesign --force --deep --sign - "${STAGE_APP}"
codesign --verify --deep --strict "${STAGE_APP}"

print "Creating and validating ${ARCHIVE_NAME}…"
ditto -c -k --keepParent "${STAGE_APP}" "${STAGE_ARCHIVE}"
unzip -t "${STAGE_ARCHIVE}" >/dev/null

# Build the portal-upload extension archives before removing any prior app
# output. This keeps the complete release workflow to one command.
"${SCRIPT_DIR}/package-browser-extensions.command"

# Do not discard the old generated output until the replacement is verified.
mkdir -p "$DIST_DIR"
if [[ "$KEEP_OLD" != true ]]; then
  clean_generated_dist
fi
ditto "${STAGE_APP}" "$DIST_APP"
ditto "${STAGE_ARCHIVE}" "${DIST_DIR}/${ARCHIVE_NAME}"

ARCHIVE_SHA=$(shasum -a 256 "${DIST_DIR}/${ARCHIVE_NAME}" | awk '{print $1}')
print ""
print "Build succeeded."
print "App:     ${DIST_APP}"
print "Package: ${DIST_DIR}/${ARCHIVE_NAME}"
print "SHA-256: ${ARCHIVE_SHA}"
