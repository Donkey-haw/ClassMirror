#!/usr/bin/env bash
set -euo pipefail

UXPLAY_VERSION="v1.73.7"
UXPLAY_RELEASE="${UXPLAY_VERSION#v}"
UXPLAY_COMMIT="df67c212a433cf6dda3676dd40c097900d24e645"
UXPLAY_ARCHIVE_SHA256="65feb8732de666a7161a9e562aa603a7f5fe0ebb890c2a30c5e1a9c85c76309f"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE0_DIR="$ROOT_DIR/.phase0"
ARCHIVE="$PHASE0_DIR/UxPlay-$UXPLAY_VERSION.tar.gz"
SOURCE_DIR="$PHASE0_DIR/UxPlay-$UXPLAY_RELEASE"
BUILD_DIR="$PHASE0_DIR/build-uxplay"
DOWNLOAD_URL="https://codeload.github.com/FDH2/UxPlay/tar.gz/refs/tags/$UXPLAY_VERSION"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "필요한 도구가 없습니다: $1" >&2
    exit 1
  fi
}

require_pkg() {
  if ! pkg-config --exists "$1"; then
    echo "필요한 pkg-config 패키지가 없습니다: $1" >&2
    exit 1
  fi
}

require_command curl
require_command shasum
require_command tar
require_command cmake
require_command pkg-config
require_pkg openssl
require_pkg libplist-2.0
require_pkg gstreamer-1.0

mkdir -p "$PHASE0_DIR"

if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --silent --show-error "$DOWNLOAD_URL" --output "$ARCHIVE"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$UXPLAY_ARCHIVE_SHA256" ]]; then
  echo "UxPlay 소스 해시가 예상값과 다릅니다." >&2
  echo "expected: $UXPLAY_ARCHIVE_SHA256" >&2
  echo "actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  tar -xzf "$ARCHIVE" -C "$PHASE0_DIR"
fi

cmake \
  -S "$SOURCE_DIR" \
  -B "$BUILD_DIR" \
  -DNO_MARCH_NATIVE=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --parallel "$(sysctl -n hw.ncpu)"

UXPLAY_BINARY="$BUILD_DIR/uxplay"
if [[ ! -x "$UXPLAY_BINARY" ]]; then
  echo "UxPlay 바이너리가 생성되지 않았습니다: $UXPLAY_BINARY" >&2
  exit 1
fi

echo "UxPlay Phase 0 기준선 준비 완료"
echo "version: $UXPLAY_VERSION"
echo "commit:  $UXPLAY_COMMIT"
echo "binary:  $UXPLAY_BINARY"
