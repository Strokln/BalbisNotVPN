#!/bin/sh
# Pinned release assets; no global installation or elevated access.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/bin"
for ARCH in x86_64 arm64; do
  case "$ARCH" in
    x86_64) ASSET=amd64; SHA=bf68aeac95311d9a7c7229249a3188901bb252beff18737e2643e2558efcbb2a;;
    arm64) ASSET=arm64; SHA=9f2b2b268d5d5ffe272cc40f07df374190becab65117512d683f3a17b90a9d25;;
  esac
  TEMP_ASSET=$(mktemp "$ROOT/bin/.download.XXXXXX")
  trap 'rm -f "$TEMP_ASSET"' EXIT HUP INT TERM
  curl -fL "https://github.com/Alexey71/opera-proxy/releases/download/v1.31.0/opera-proxy.darwin-$ASSET" -o "$TEMP_ASSET"
  printf '%s  %s\n' "$SHA" "$TEMP_ASSET" | shasum -a 256 -c -
  chmod 755 "$TEMP_ASSET"
  mv "$TEMP_ASSET" "$ROOT/bin/opera-proxy-$ARCH"
done
