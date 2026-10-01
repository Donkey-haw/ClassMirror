#!/usr/bin/env bash
set -euo pipefail

SIGNING_IDENTITY="${CLASSMIRROR_SIGNING_IDENTITY:?Set CLASSMIRROR_SIGNING_IDENTITY to a Developer ID Application certificate name.}"
NOTARY_PROFILE="${CLASSMIRROR_NOTARY_PROFILE:?Set CLASSMIRROR_NOTARY_PROFILE to an xcrun notarytool keychain profile.}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist-release/ClassMirror.app"
RELEASE_VERSION="${CLASSMIRROR_RELEASE_VERSION:-0.1.0}"
DISK_IMAGE="$ROOT_DIR/dist-release/ClassMirror-${RELEASE_VERSION}-macos-arm64.dmg"
CHECKSUM_FILE="$DISK_IMAGE.sha256"

CLASSMIRROR_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
CLASSMIRROR_RELEASE_VERSION="$RELEASE_VERSION" \
  "$ROOT_DIR/script/package_release.sh"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if codesign -d --verbose=4 "$APP_BUNDLE" 2>&1 | grep -q 'Signature=adhoc'; then
  echo "Developer ID signing was not applied; refusing to submit." >&2
  exit 1
fi

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DISK_IMAGE"

xcrun notarytool submit \
  "$DISK_IMAGE" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DISK_IMAGE"
xcrun stapler validate "$DISK_IMAGE"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$DISK_IMAGE"

(
  cd "$(dirname "$DISK_IMAGE")"
  shasum -a 256 "$(basename "$DISK_IMAGE")" > "$(basename "$CHECKSUM_FILE")"
)

printf '%s\n%s\n' "$DISK_IMAGE" "$CHECKSUM_FILE"
