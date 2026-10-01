#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
if [[ "$MODE" != "build" && "$MODE" != "--download-only" ]]; then
  echo "usage: $0 [--download-only]" >&2
  exit 2
fi

OPENSSL_VERSION="3.6.4"
OPENSSL_SHA256="9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef"
LIBPLIST_VERSION="2.7.0"
LIBPLIST_SHA256="7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b"
DEPLOYMENT_TARGET="${CLASSMIRROR_DEPLOYMENT_TARGET:-15.0}"
BUILD_REVISION="2"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/.vendor"
BUNDLED_SOURCE_DIR="$ROOT_DIR/vendor-sources"
DOWNLOAD_DIR="$VENDOR_DIR/downloads"
SOURCE_DIR="$VENDOR_DIR/sources"
PREFIX_DIR="$VENDOR_DIR/prefix-macos${DEPLOYMENT_TARGET}-arm64"
MARKER="$PREFIX_DIR/.classmirror-dependencies-complete"
OPENSSL_ARCHIVE="$DOWNLOAD_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
LIBPLIST_ARCHIVE="$DOWNLOAD_DIR/libplist-${LIBPLIST_VERSION}.tar.bz2"
OPENSSL_SOURCE="$SOURCE_DIR/openssl-${OPENSSL_VERSION}"
LIBPLIST_SOURCE="$SOURCE_DIR/libplist-${LIBPLIST_VERSION}"
BUILD_JOBS="$(sysctl -n hw.logicalcpu)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
LIBPLIST_BUILD_ROOT="${TMPDIR%/}/classmirror-libplist-${LIBPLIST_VERSION}-$(id -u)"
LIBPLIST_BUILD_SOURCE="$LIBPLIST_BUILD_ROOT/source"
LIBPLIST_STAGE="$LIBPLIST_BUILD_ROOT/stage"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "ClassMirror release dependencies require an Apple Silicon Mac." >&2
  exit 1
fi

mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$PREFIX_DIR"

if [[ -f "$BUNDLED_SOURCE_DIR/$(basename "$OPENSSL_ARCHIVE")" && ! -f "$OPENSSL_ARCHIVE" ]]; then
  cp "$BUNDLED_SOURCE_DIR/$(basename "$OPENSSL_ARCHIVE")" "$OPENSSL_ARCHIVE"
fi
if [[ -f "$BUNDLED_SOURCE_DIR/$(basename "$LIBPLIST_ARCHIVE")" && ! -f "$LIBPLIST_ARCHIVE" ]]; then
  cp "$BUNDLED_SOURCE_DIR/$(basename "$LIBPLIST_ARCHIVE")" "$LIBPLIST_ARCHIVE"
fi

download_and_verify() {
  local url="$1"
  local destination="$2"
  local expected_sha="$3"

  if [[ ! -f "$destination" ]]; then
    curl --fail --location --retry 3 --output "$destination" "$url"
  fi
  local actual_sha
  actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Checksum mismatch: $destination" >&2
    exit 1
  fi
}

download_and_verify \
  "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
  "$OPENSSL_ARCHIVE" \
  "$OPENSSL_SHA256"
download_and_verify \
  "https://github.com/libimobiledevice/libplist/releases/download/${LIBPLIST_VERSION}/libplist-${LIBPLIST_VERSION}.tar.bz2" \
  "$LIBPLIST_ARCHIVE" \
  "$LIBPLIST_SHA256"

if [[ "$MODE" == "--download-only" ]]; then
  printf '%s\n%s\n' "$OPENSSL_ARCHIVE" "$LIBPLIST_ARCHIVE"
  exit 0
fi

if [[ -f "$MARKER" ]] && grep -q "build revision ${BUILD_REVISION}" "$MARKER"; then
  printf '%s\n' "$PREFIX_DIR"
  exit 0
fi

if [[ ! -d "$OPENSSL_SOURCE" ]]; then
  tar -xf "$OPENSSL_ARCHIVE" -C "$SOURCE_DIR"
fi
if [[ ! -d "$LIBPLIST_SOURCE" ]]; then
  tar -xf "$LIBPLIST_ARCHIVE" -C "$SOURCE_DIR"
fi

if [[ ! -f "$PREFIX_DIR/lib/libcrypto.a" \
      || ! -f "$PREFIX_DIR/lib/libssl.a" \
      || ! -f "$MARKER" \
      || ! "$(cat "$MARKER")" =~ "build revision ${BUILD_REVISION}" ]]; then
  (
    cd "$OPENSSL_SOURCE"
    make clean >/dev/null 2>&1 || true
    env \
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      SDKROOT="$SDK_PATH" \
      CC="$(xcrun --find clang)" \
      CFLAGS="-O2 -isysroot $SDK_PATH -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
      ./Configure \
        darwin64-arm64-cc \
        no-shared \
        no-tests \
        no-ssl3 \
        no-ssl3-method \
        no-zlib \
        --prefix=/ \
        --openssldir=/etc/ssl \
        --libdir=lib
    make -j "$BUILD_JOBS"
    make install_sw DESTDIR="$PREFIX_DIR"
  )
fi

if [[ ! -f "$PREFIX_DIR/lib/libplist-2.0.a" ]]; then
  mkdir -p "$LIBPLIST_BUILD_SOURCE" "$LIBPLIST_STAGE"
  if [[ ! -x "$LIBPLIST_BUILD_SOURCE/configure" ]]; then
    tar -xf "$LIBPLIST_ARCHIVE" \
      -C "$LIBPLIST_BUILD_SOURCE" \
      --strip-components=1
  fi
  (
    cd "$LIBPLIST_BUILD_SOURCE"
    env \
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      SDKROOT="$SDK_PATH" \
      CC="$(xcrun --find clang)" \
      CFLAGS="-O2 -isysroot $SDK_PATH -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
      ./configure \
        --prefix="$LIBPLIST_STAGE" \
        --disable-shared \
        --enable-static \
        --without-cython \
        --without-tests
    make -j "$BUILD_JOBS"
    make install
  )
  mkdir -p "$PREFIX_DIR/include" "$PREFIX_DIR/lib/pkgconfig"
  cp -R "$LIBPLIST_STAGE/include/." "$PREFIX_DIR/include/"
  cp "$LIBPLIST_STAGE/lib/libplist-2.0.a" "$PREFIX_DIR/lib/"
  sed "s|^prefix=.*|prefix=$PREFIX_DIR|" \
    "$LIBPLIST_STAGE/lib/pkgconfig/libplist-2.0.pc" \
    > "$PREFIX_DIR/lib/pkgconfig/libplist-2.0.pc"
fi

printf 'OpenSSL %s\nlibplist %s\nmacOS deployment target %s\n' \
  "$OPENSSL_VERSION" "$LIBPLIST_VERSION" "$DEPLOYMENT_TARGET" > "$MARKER"
printf 'build revision %s\n' "$BUILD_REVISION" >> "$MARKER"
printf '%s\n' "$PREFIX_DIR"
