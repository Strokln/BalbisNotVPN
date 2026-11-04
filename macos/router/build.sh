#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in x86_64) GO_ARCH=amd64;; arm64) GO_ARCH=arm64;; *) echo 'Expected x86_64 or arm64' >&2; exit 2;; esac
OUTPUT="${2:-$ROOT/../build/objects/balbis-router-$ARCH}"
[[ "$OUTPUT" = /* ]] || OUTPUT="$PWD/$OUTPUT"
if [[ -n "${GO_BIN:-}" ]]; then COMPILER="$GO_BIN"
elif command -v go >/dev/null 2>&1; then COMPILER="$(command -v go)"
else
    COMPILER="$ROOT/../build/tools/go/bin/go"
    if [[ ! -x "$COMPILER" ]]; then "$ROOT/../tunnel/fetch-go.sh"; fi
fi
mkdir -p "$(dirname "$OUTPUT")" "$ROOT/../build/go-cache"
cd "$ROOT"
env GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=darwin GOARCH="$GO_ARCH" GOCACHE="$ROOT/../build/go-cache" \
    "$COMPILER" build -buildvcs=false -trimpath -ldflags='-s -w -buildid=' -o "$OUTPUT" .
