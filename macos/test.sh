#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/build/tests"
python3 "$ROOT/macos/tests/test_localizations.py"
# Keep snapshot tests deterministic without changing the user’s language preferences.
export AppleLanguages="(ru)"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/ProxyHelperClient.swift" "$ROOT/macos/Helper/HelperProtocol.swift" \
    "$ROOT/macos/Sources/BuiltInSites.swift" "$ROOT/macos/Sources/ExcludedSites.swift" "$ROOT/macos/Sources/ConnectionEvents.swift" "$ROOT/macos/Sources/CustomSites.swift" "$ROOT/macos/Sources/Localization.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/PACServer.swift" "$ROOT/macos/Sources/Runtime.swift" "$ROOT/macos/Sources/ForeignTunnel.swift" \
    "$ROOT/macos/tests/BuiltInSitesTests.swift" "$ROOT/macos/tests/ExcludedSitesTests.swift" "$ROOT/macos/Sources/ConnectionHealth.swift" "$ROOT/macos/tests/RecoveryTests.swift" "$ROOT/macos/tests/CoreTests.swift" -framework Network -framework JavaScriptCore \
    -o "$ROOT/macos/build/tests/core-tests"
"$ROOT/macos/build/tests/core-tests" "$ROOT/macos" -AppleLanguages "(ru)"
python3 "$ROOT/macos/tests/test_engine.py" -v
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/Localization.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/ProxyHelperClient.swift" \
    "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/tests/HelperClientTests.swift" \
    -o "$ROOT/macos/build/tests/helper-client-tests"
"$ROOT/macos/build/tests/helper-client-tests" -AppleLanguages "(ru)"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/Helper/main.swift" \
    -framework SystemConfiguration -o "$ROOT/macos/build/tests/proxy-helper"
"$ROOT/macos/build/tests/proxy-helper" --self-test
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/StartupConnection.swift" "$ROOT/macos/tests/StartupConnectionTests.swift" \
    -framework Network -o "$ROOT/macos/build/tests/startup-tests"
"$ROOT/macos/build/tests/startup-tests" -AppleLanguages "(ru)"
panel_sources=()
for source in "$ROOT"/macos/Sources/*.swift; do
    if [[ "$(basename "$source")" != main.swift ]]; then panel_sources+=("$source"); fi
done
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "${panel_sources[@]}" "$ROOT/macos/Helper/HelperProtocol.swift" \
    "$ROOT/macos/tests/StartupSettingsTests.swift" -framework Cocoa -framework Network \
    -o "$ROOT/macos/build/tests/startup-settings-tests"
balbis_startup_test_home=$(mktemp -d "${TMPDIR:-/tmp/}balbis-startup.XXXXXX")
CFFIXED_USER_HOME="$balbis_startup_test_home" "$ROOT/macos/build/tests/startup-settings-tests"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "${panel_sources[@]}" "$ROOT/macos/Helper/HelperProtocol.swift" \
    "$ROOT/macos/tests/ConnectionHealthTests.swift" -framework Cocoa -framework Network \
    -o "$ROOT/macos/build/tests/connection-health-tests"
"$ROOT/macos/build/tests/connection-health-tests" -AppleLanguages "(ru)"

xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/Localization.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/ProxyHelperClient.swift" \
    "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/Sources/DiagnosticReport.swift" \
    "$ROOT/macos/tests/DiagnosticReportTests.swift" -framework Cocoa \
    -o "$ROOT/macos/build/tests/diagnostic-report-tests"
"$ROOT/macos/build/tests/diagnostic-report-tests" -AppleLanguages "(ru)"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/Localization.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/ProxyHelperClient.swift" \
    "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/Sources/ConnectionEvents.swift" \
    "$ROOT/macos/Sources/ConnectionNotices.swift" "$ROOT/macos/tests/RecoveryNoticeTests.swift" \
    -framework Cocoa -o "$ROOT/macos/build/tests/recovery-notice-tests"
"$ROOT/macos/build/tests/recovery-notice-tests" -AppleLanguages "(ru)"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "$ROOT/macos/Sources/Localization.swift" "$ROOT/macos/Sources/Core.swift" "$ROOT/macos/Sources/ProxyHelperClient.swift" \
    "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/Sources/Updates.swift" \
    "$ROOT/macos/Sources/ConnectionProblem.swift" "$ROOT/macos/tests/ProductFeaturesTests.swift" \
    -framework Cocoa -o "$ROOT/macos/build/tests/product-features-tests"
"$ROOT/macos/build/tests/product-features-tests" -AppleLanguages "(ru)"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$ROOT/macos/build/module-cache" \
    "${panel_sources[@]}" "$ROOT/macos/Helper/HelperProtocol.swift" \
    "$ROOT/macos/tests/AutomaticExitSelectionTests.swift" -framework Cocoa -framework Network \
    -o "$ROOT/macos/build/tests/automatic-exit-selection-tests"
"$ROOT/macos/build/tests/automatic-exit-selection-tests" -AppleLanguages "(ru)"
