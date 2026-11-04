#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REV=73ee2aa04e6e94922e7dc07554a1c3a456dc3201
SHA=dcef784d413ef95e98b34f0b657aac801b1f9b0601d6d9d95f6bf418d18e4533
TMP_FETCH=$(mktemp -d)
trap 'rm -rf "$TMP_FETCH"' EXIT HUP INT TERM
curl -fL "https://github.com/bol-van/zapret/archive/$REV.tar.gz" -o "$TMP_FETCH/source.tar.gz"
printf '%s  %s\n' "$SHA" "$TMP_FETCH/source.tar.gz" | shasum -a 256 -c -
mkdir -p "$ROOT/vendor"
tar -xzf "$TMP_FETCH/source.tar.gz" -C "$TMP_FETCH" "zapret-$REV/tpws" "zapret-$REV/docs/LICENSE.txt" "zapret-$REV/docs/readme.en.md"
# Do not overwrite a modified vendor checkout.
if [ -e "$ROOT/vendor/zapret-$REV" ]; then
  echo 'Pinned vendor tree already exists; archive verified.'
else
  mv "$TMP_FETCH/zapret-$REV" "$ROOT/vendor/"
fi
