#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UXPLAY_BINARY="$ROOT_DIR/.phase0/build-uxplay/uxplay"
RECEIVER_NAME="${CLASSMIRROR_PHASE0_NAME:-ClassMirror-Phase0}"

if [[ ! -x "$UXPLAY_BINARY" ]]; then
  echo "먼저 ./script/bootstrap_phase0.sh 를 실행하세요." >&2
  exit 1
fi

exec "$UXPLAY_BINARY" \
  -n "$RECEIVER_NAME" \
  -nh \
  -pw \
  -nofreeze \
  -vsync no \
  "$@"
