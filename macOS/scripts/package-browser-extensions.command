#!/bin/zsh
# Produce portal-upload packages from the audited extension source folders.
# The packages are deliberately not signed: Chrome Web Store and Firefox AMO
# perform their own signing after the developer uploads them.

set -euo pipefail
setopt NULL_GLOB

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:t}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CHROME_SOURCE="${PROJECT_DIR}/chrome-extension"
FIREFOX_SOURCE="${PROJECT_DIR}/firefox-extension"
DIST_DIR="${PROJECT_DIR}/dist/extensions"
KEEP_OLD=false

usage() {
  print "Usage: ${SCRIPT_NAME} [--keep-old]"
  print "  --keep-old  Preserve previous generated extension packages."
}

case "${1:-}" in
  "") ;;
  --keep-old) KEEP_OLD=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 64 ;;
esac

require_path() {
  if [[ ! -e "$1" ]]; then
    print -u2 "Missing required extension input: $1"
    exit 66
  fi
}

extension_version() {
  local version
  version=$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1")
  if [[ -z "$version" ]]; then
    print -u2 "Could not read extension version from: $1"
    exit 67
  fi
  print "$version"
}

clean_generated_packages() {
  local artifact
  local -a artifacts
  artifacts=(
    "${DIST_DIR}"/XDM-New-Chrome-extension-*.zip(N)
    "${DIST_DIR}"/XDM-New-Firefox-extension-*.xpi(N)
    "${DIST_DIR}/SHA256SUMS.txt"
  )

  for artifact in "${artifacts[@]}"; do
    [[ -e "$artifact" ]] || continue
    case "$artifact" in
      "${DIST_DIR}"/*) ;;
      *) print -u2 "Refusing to remove an unexpected path: $artifact"; exit 70 ;;
    esac
    print "Removing previous generated package: ${artifact:t}"
    /bin/rm -rf "$artifact"
  done
}

require_path "${CHROME_SOURCE}/manifest.json"
require_path "${FIREFOX_SOURCE}/manifest.json"
require_path "${CHROME_SOURCE}/background.js"
require_path "${FIREFOX_SOURCE}/background.js"

CHROME_VERSION=$(extension_version "${CHROME_SOURCE}/manifest.json")
FIREFOX_VERSION=$(extension_version "${FIREFOX_SOURCE}/manifest.json")
if [[ "$CHROME_VERSION" != "$FIREFOX_VERSION" ]]; then
  print -u2 "Chrome (${CHROME_VERSION}) and Firefox (${FIREFOX_VERSION}) versions must match."
  exit 65
fi

VERSION="$CHROME_VERSION"
CHROME_PACKAGE="XDM-New-Chrome-extension-${VERSION}.zip"
FIREFOX_PACKAGE="XDM-New-Firefox-extension-${VERSION}.xpi"
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xdm-new-extensions.XXXXXX")
CHROME_STAGE="${STAGE_DIR}/chrome-extension"
FIREFOX_STAGE="${STAGE_DIR}/firefox-extension"
STAGE_CHROME_PACKAGE="${STAGE_DIR}/${CHROME_PACKAGE}"
STAGE_FIREFOX_PACKAGE="${STAGE_DIR}/${FIREFOX_PACKAGE}"

cleanup_stage() {
  /bin/rm -rf "$STAGE_DIR"
}
trap cleanup_stage EXIT

print "Preparing XDM New browser extensions ${VERSION}…"
ditto "${CHROME_SOURCE}" "$CHROME_STAGE"
ditto "${FIREFOX_SOURCE}" "$FIREFOX_STAGE"
xattr -cr "$CHROME_STAGE" "$FIREFOX_STAGE"

# Both archives contain manifest.json at their root, as required by their
# respective extension portals. The Chrome ZIP is uploaded to the Web Store;
# the Firefox XPI is uploaded to AMO for signing.
(
  cd "$CHROME_STAGE"
  /usr/bin/zip -X -q -r "$STAGE_CHROME_PACKAGE" . -x '*/.DS_Store'
)
(
  cd "$FIREFOX_STAGE"
  /usr/bin/zip -X -q -r "$STAGE_FIREFOX_PACKAGE" . -x '*/.DS_Store'
)

unzip -t "$STAGE_CHROME_PACKAGE" >/dev/null
unzip -t "$STAGE_FIREFOX_PACKAGE" >/dev/null
unzip -Z1 "$STAGE_CHROME_PACKAGE" | grep -qx 'manifest.json'
unzip -Z1 "$STAGE_FIREFOX_PACKAGE" | grep -qx 'manifest.json'

mkdir -p "$DIST_DIR"
if [[ "$KEEP_OLD" != true ]]; then
  clean_generated_packages
fi
ditto "$STAGE_CHROME_PACKAGE" "${DIST_DIR}/${CHROME_PACKAGE}"
ditto "$STAGE_FIREFOX_PACKAGE" "${DIST_DIR}/${FIREFOX_PACKAGE}"
(
  cd "$DIST_DIR"
  shasum -a 256 "$CHROME_PACKAGE" "$FIREFOX_PACKAGE" > SHA256SUMS.txt
)

print ""
print "Extension packages ready for portal upload:"
print "Chrome Web Store: ${DIST_DIR}/${CHROME_PACKAGE}"
print "Firefox AMO:      ${DIST_DIR}/${FIREFOX_PACKAGE}"
print "Checksums:        ${DIST_DIR}/SHA256SUMS.txt"
