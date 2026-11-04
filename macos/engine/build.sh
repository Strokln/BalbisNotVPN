#!/bin/sh
# Build without Homebrew, root, or globally installed dependencies.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCH=${1:-${ARCH:-$(uname -m)}}
case "$ARCH" in x86_64|arm64) ;; *) echo 'architecture must be x86_64 or arm64' >&2; exit 2;; esac
OUTPUT=${2:-"$ROOT/bin/tpws-$ARCH"}
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT";; esac
SRC="$ROOT/vendor/zapret-73ee2aa04e6e94922e7dc07554a1c3a456dc3201/tpws"
mkdir -p "$(dirname "$OUTPUT")"
TMP_BUILD=$(mktemp -d)
trap 'rm -rf "$TMP_BUILD"' EXIT HUP INT TERM
cp -R "$SRC/." "$TMP_BUILD/"
if [ "${BALBIS_TEST_ALLOW_LOOPBACK:-0}" = 1 ]; then
  patch -s -d "$TMP_BUILD" -p1 < "$ROOT/test-loopback.patch"
fi
cd "$TMP_BUILD"
xcrun clang -std=gnu99 -Os -Wno-address-of-packed-member \
  -Iepoll-shim/include -Imacos -target "$ARCH-apple-macos13.0" \
  *.c epoll-shim/src/*.c -lz -lpthread -Wl,-dead_strip -o "$OUTPUT"
printf '%s\n' "$OUTPUT"
