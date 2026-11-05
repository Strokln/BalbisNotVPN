#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$ROOT/macos/build/Balbis.app/Contents/Resources/list/main.txt" ]]; then
    echo 'Build the app first: ./macos/build.sh' >&2
    exit 2
fi
mkdir -p "$ROOT/macos/build/tests"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/ProxyHelperClient.swift" "$ROOT/macos/Helper/HelperProtocol.swift" \
    "$ROOT/macos/Sources/BuiltInSites.swift" "$ROOT/macos/Sources/ExcludedSites.swift" "$ROOT/macos/Sources/ConnectionEvents.swift" "$ROOT/macos/Sources/CustomSites.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/PACServer.swift" "$ROOT/macos/Sources/Runtime.swift" "$ROOT/macos/Sources/ForeignTunnel.swift" \
    "$ROOT/macos/tests/RuntimeTests.swift" -framework Network \
    -o "$ROOT/macos/build/tests/runtime-tests"
# Keep the live installation and its recovery journal outside lifecycle tests.
balbis_test_home=$(mktemp -d "${TMPDIR:-/tmp/}balbis-runtime.XXXXXX")
CFFIXED_USER_HOME="$balbis_test_home" "$ROOT/macos/build/tests/runtime-tests" "$ROOT/macos/build/Balbis.app" "$@"
