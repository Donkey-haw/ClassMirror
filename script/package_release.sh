#!/usr/bin/env bash
set -euo pipefail

RELEASE_VERSION="${CLASSMIRROR_RELEASE_VERSION:-0.1.0-alpha.1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist-release"
APP_BUNDLE="$DIST_DIR/ClassMirror.app"
STAGING_DIR="$DIST_DIR/dmg-staging"
DISK_IMAGE="$DIST_DIR/ClassMirror-${RELEASE_VERSION}-macos-arm64.dmg"
CHECKSUM_FILE="$DISK_IMAGE.sha256"

"$ROOT_DIR/script/build_release.sh"

rm -rf "$STAGING_DIR" "$DISK_IMAGE" "$CHECKSUM_FILE"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/ClassMirror.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "ClassMirror ${RELEASE_VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DISK_IMAGE"

rm -rf "$STAGING_DIR"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DISK_IMAGE")" > "$(basename "$CHECKSUM_FILE")"
)

printf '%s\n%s\n' "$DISK_IMAGE" "$CHECKSUM_FILE"
