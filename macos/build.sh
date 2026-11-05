#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/macos/build"
APP="$BUILD/Balbis.app"
ARCH="${1:-universal}"
case "$ARCH" in universal) ARCHES=(x86_64 arm64);; x86_64|arm64) ARCHES=("$ARCH");; *) echo 'Usage: macos/build.sh [universal|x86_64|arm64]' >&2; exit 2;; esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/list" "$BUILD/objects"
for arch in "${ARCHES[@]}"; do
    "$ROOT/macos/engine/build.sh" "$arch" "$BUILD/objects/tpws-$arch"
    "$ROOT/macos/router/build.sh" "$arch" "$BUILD/objects/balbis-router-$arch"
    if [[ ! -f "$ROOT/macos/tunnel/bin/opera-proxy-$arch" ]]; then "$ROOT/macos/tunnel/fetch.sh"; fi
    xcrun swiftc -O -target "$arch-apple-macos13.0" -module-cache-path "$BUILD/module-cache" \
        "$ROOT/macos/Helper/HelperProtocol.swift" "$ROOT/macos/Helper/main.swift" \
        -framework SystemConfiguration -o "$BUILD/objects/balbis-proxy-helper-$arch"
    xcrun swiftc -O -target "$arch-apple-macos13.0" -module-cache-path "$BUILD/module-cache" \
        "$ROOT"/macos/Sources/*.swift "$ROOT/macos/Helper/HelperProtocol.swift" -o "$BUILD/objects/Balbis-$arch" \
        -framework Cocoa -framework Network
 done
if [[ "$ARCH" == universal ]]; then
    xcrun lipo -create "$BUILD/objects/balbis-proxy-helper-x86_64" "$BUILD/objects/balbis-proxy-helper-arm64" -output "$APP/Contents/Resources/balbis-proxy-helper"
    xcrun lipo -create "$BUILD/objects/Balbis-x86_64" "$BUILD/objects/Balbis-arm64" -output "$APP/Contents/MacOS/Balbis"
    xcrun lipo -create "$BUILD/objects/tpws-x86_64" "$BUILD/objects/tpws-arm64" -output "$APP/Contents/Resources/tpws"
    xcrun lipo -create "$BUILD/objects/balbis-router-x86_64" "$BUILD/objects/balbis-router-arm64" -output "$APP/Contents/Resources/balbis-router"
    xcrun lipo -create "$ROOT/macos/tunnel/bin/opera-proxy-x86_64" "$ROOT/macos/tunnel/bin/opera-proxy-arm64" -output "$APP/Contents/Resources/opera-proxy"
else
    cp "$BUILD/objects/balbis-proxy-helper-$ARCH" "$APP/Contents/Resources/balbis-proxy-helper"
    cp "$BUILD/objects/Balbis-$ARCH" "$APP/Contents/MacOS/Balbis"
    cp "$BUILD/objects/tpws-$ARCH" "$APP/Contents/Resources/tpws"
    cp "$BUILD/objects/balbis-router-$ARCH" "$APP/Contents/Resources/balbis-router"
    cp "$ROOT/macos/tunnel/bin/opera-proxy-$ARCH" "$APP/Contents/Resources/opera-proxy"
fi
mkdir -p "$APP/Contents/Resources/routing" "$APP/Contents/Resources/licenses-opera"
cp "$ROOT"/macos/routing/*.txt "$APP/Contents/Resources/routing/"
cp "$ROOT/macos/tunnel/LICENSE" "$APP/Contents/Resources/licenses-opera/LICENSE"
cp "$ROOT/macos/tunnel/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/licenses-opera/THIRD_PARTY_NOTICES.md"
cp -R "$ROOT/macos/tunnel/licenses/." "$APP/Contents/Resources/licenses-opera/"
cp "$ROOT"/list/*.txt "$APP/Contents/Resources/list/"
cp "$ROOT/macos/Resources/Balbis.icns" "$APP/Contents/Resources/Balbis.icns"
cp "$ROOT/macos/README.md" "$APP/Contents/Resources/README-macOS.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE-Balbis.txt"
cp "$ROOT/macos/engine/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES-tpws.txt"
cp "$ROOT/macos/engine/vendor/zapret-73ee2aa04e6e94922e7dc07554a1c3a456dc3201/docs/LICENSE.txt" "$APP/Contents/Resources/LICENSE-tpws.txt"
cp "$ROOT/macos/engine/EPOLL-SHIM-LICENSE" "$APP/Contents/Resources/EPOLL-SHIM-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.balbis.macos</string>
<key>CFBundleName</key><string>Balbis</string>
<key>CFBundleDisplayName</key><string>Balbis</string>
<key>CFBundleIconFile</key><string>Balbis.icns</string>
<key>CFBundleExecutable</key><string>Balbis</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.1</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Balbis by Strokin © 2026. See bundled licenses and notices.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/balbis-proxy-helper"
codesign --force --sign - "$APP/Contents/Resources/balbis-router"
codesign --force --sign - "$APP/Contents/Resources/opera-proxy"
codesign --force --sign - "$APP/Contents/Resources/tpws"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Balbis-macOS-13-$ARCH.zip"
shasum -a 256 "$BUILD/Balbis-macOS-13-$ARCH.zip" > "$BUILD/Balbis-macOS-13-$ARCH.zip.sha256"
echo "Built: $APP"
