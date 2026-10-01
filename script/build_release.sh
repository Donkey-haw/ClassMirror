#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ClassMirror"
BUNDLE_ID="${CLASSMIRROR_BUNDLE_ID:-com.classmirror.mac}"
SIGNING_IDENTITY="${CLASSMIRROR_SIGNING_IDENTITY:--}"
DEPLOYMENT_TARGET="${CLASSMIRROR_DEPLOYMENT_TARGET:-15.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSMIRROR_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  "$ROOT_DIR/script/build_vendor_dependencies.sh"
PREFIX_DIR="$ROOT_DIR/.vendor/prefix-macos${DEPLOYMENT_TARGET}-arm64"
LINK_PREFIX="${TMPDIR%/}/classmirror-release-dependencies-$(id -u)-macos${DEPLOYMENT_TARGET}"
LINK_PKGCONFIG="$LINK_PREFIX/pkgconfig"
BUILD_DIR="$ROOT_DIR/.build-release"
DIST_DIR="$ROOT_DIR/dist-release"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

mkdir -p "$LINK_PREFIX" "$LINK_PKGCONFIG"
ln -sfn "$PREFIX_DIR/include" "$LINK_PREFIX/include"
ln -sfn "$PREFIX_DIR/lib" "$LINK_PREFIX/lib"
for package_config in openssl libssl libcrypto libplist-2.0; do
  sed "s|^prefix=.*|prefix=$LINK_PREFIX|" \
    "$PREFIX_DIR/lib/pkgconfig/$package_config.pc" \
    > "$LINK_PKGCONFIG/$package_config.pc"
done

export PKG_CONFIG_PATH="$LINK_PKGCONFIG"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

swift package \
  --package-path "$ROOT_DIR" \
  --scratch-path "$BUILD_DIR" \
  clean

if [[ "${CLASSMIRROR_SKIP_TESTS:-0}" != "1" ]]; then
  swift test \
    --package-path "$ROOT_DIR" \
    --configuration release \
    --scratch-path "$BUILD_DIR"
fi

swift build \
  --package-path "$ROOT_DIR" \
  --configuration release \
  --scratch-path "$BUILD_DIR"
BUILD_BIN_DIR="$(swift build \
  --package-path "$ROOT_DIR" \
  --configuration release \
  --scratch-path "$BUILD_DIR" \
  --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/ThirdPartyNotices"
cp "$BUILD_BIN_DIR/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
cp "$ROOT_DIR/LICENSE" \
  "$APP_RESOURCES/ThirdPartyNotices/UxPlay-GPL-3.0.txt"
cp "$ROOT_DIR/ThirdParty/AirPlayCoreTarget/Upstream/playfair/LICENSE.md" \
  "$APP_RESOURCES/ThirdPartyNotices/PlayFair-GPL-3.0.txt"
cp "$ROOT_DIR/ThirdParty/AirPlayCoreTarget/Upstream/llhttp/LICENSE-MIT" \
  "$APP_RESOURCES/ThirdPartyNotices/llhttp-MIT.txt"
cp "$ROOT_DIR/.vendor/sources/openssl-3.6.4/LICENSE.txt" \
  "$APP_RESOURCES/ThirdPartyNotices/OpenSSL-Apache-2.0.txt"
cp "$ROOT_DIR/.vendor/sources/libplist-2.7.0/COPYING.LESSER" \
  "$APP_RESOURCES/ThirdPartyNotices/libplist-LGPL-2.1.txt"

while IFS= read -r development_rpath; do
  install_name_tool -delete_rpath "$development_rpath" "$APP_BINARY"
done < <(
  otool -l "$APP_BINARY" \
    | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' \
    | grep '^/Applications/Xcode' || true
)

if otool -L "$APP_BINARY" | grep -Eq '/opt/homebrew|/usr/local'; then
  echo "Release binary still depends on a package-manager library." >&2
  otool -L "$APP_BINARY" >&2
  exit 1
fi

codesign_arguments=(
  --force
  --deep
  --options runtime
  --sign "$SIGNING_IDENTITY"
  --identifier "$BUNDLE_ID"
)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign_arguments+=(--timestamp)
fi
codesign "${codesign_arguments[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

printf '%s\n' "$APP_BUNDLE"
