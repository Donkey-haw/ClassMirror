#!/usr/bin/env bash
set -euo pipefail

RELEASE_VERSION="${CLASSMIRROR_RELEASE_VERSION:-0.1.0-alpha.1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist-release"
STAGING_ROOT="$DIST_DIR/source-staging"
SOURCE_DIR="$STAGING_ROOT/ClassMirror-${RELEASE_VERSION}"
SOURCE_ARCHIVE="$DIST_DIR/ClassMirror-${RELEASE_VERSION}-source.tar.gz"
CHECKSUM_FILE="$SOURCE_ARCHIVE.sha256"

mkdir -p "$DIST_DIR"
"$ROOT_DIR/script/build_vendor_dependencies.sh" --download-only >/dev/null

rm -rf "$STAGING_ROOT" "$SOURCE_ARCHIVE" "$CHECKSUM_FILE"
mkdir -p "$SOURCE_DIR/vendor-sources"

git -C "$ROOT_DIR" archive HEAD | tar -xf - -C "$SOURCE_DIR"
cp "$ROOT_DIR/.vendor/downloads/openssl-3.6.4.tar.gz" \
  "$SOURCE_DIR/vendor-sources/"
cp "$ROOT_DIR/.vendor/downloads/libplist-2.7.0.tar.bz2" \
  "$SOURCE_DIR/vendor-sources/"

tar -czf "$SOURCE_ARCHIVE" -C "$STAGING_ROOT" "$(basename "$SOURCE_DIR")"
rm -rf "$STAGING_ROOT"

(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$SOURCE_ARCHIVE")" > "$(basename "$CHECKSUM_FILE")"
)

printf '%s\n%s\n' "$SOURCE_ARCHIVE" "$CHECKSUM_FILE"
