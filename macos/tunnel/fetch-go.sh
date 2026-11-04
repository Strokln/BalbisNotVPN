#!/bin/sh
# Optional compiler for stdlib router builds, separate from prebuilt Opera.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOLS="$ROOT/../build/tools"
case "$(uname -m)" in
  x86_64) ASSET=amd64; SHA=e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da;;
  arm64) ASSET=arm64; SHA=0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3;;
  *) echo 'Unsupported compiler host architecture' >&2; exit 2;;
esac
mkdir -p "$TOOLS"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
curl -fL https://go.dev/dl/go1.26.10.darwin-$ASSET.tar.gz -o "$WORK/go.tar.gz"
printf '%s  %s\n' "$SHA" "$WORK/go.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/go.tar.gz" -C "$WORK"
if [ -d "$TOOLS/go" ]; then echo 'Compiler directory already exists; not overwriting.'; else mv "$WORK/go" "$TOOLS/go"; fi
"$TOOLS/go/bin/go" version
