#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-}"
case "$ARCH" in
    arm64) EDITION="Apple Silicon";;
    x86_64) EDITION="Intel";;
    *) echo 'Usage: macos/package-dmg.sh arm64|x86_64 [universal.zip]' >&2; exit 2;;
esac
ARCHIVE="${2:-$ROOT/macos/build/Balbis-macOS-13-universal.zip}"
python3 - "$ROOT" "$ARCH" "$EDITION" "$ARCHIVE" <<'PY'
import pathlib
import plistlib
import subprocess
import sys
import tempfile

root, arch, edition, archive = sys.argv[1:]
build = pathlib.Path(root) / "macos/build"
def run(*args):
    subprocess.run(args, check=True)

with tempfile.TemporaryDirectory(prefix="balbis-dmg-", dir=build) as temporary:
    stage = pathlib.Path(temporary)
    run("/usr/bin/ditto", "-x", "-k", archive, str(stage))
    app = stage / "Balbis.app"
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    version = info["CFBundleShortVersionString"]
    binaries = [
        "Contents/MacOS/Balbis",
        "Contents/Resources/tpws",
        "Contents/Resources/balbis-router",
        "Contents/Resources/opera-proxy",
        "Contents/Resources/balbis-proxy-helper",
    ]
    for relative in binaries:
        binary = app / relative
        thin = binary.with_name(binary.name + ".thin")
        run("/usr/bin/lipo", str(binary), "-thin", arch, "-output", str(thin))
        thin.replace(binary)
        run("/usr/bin/codesign", "--force", "--sign", "-", str(binary))
        actual = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip()
        if actual != arch:
            raise RuntimeError(f"Unexpected architecture in {relative}: {actual}")
    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    image = build / f"Balbis-{version}-macOS-{arch}.dmg"
    run("/usr/bin/hdiutil", "create", "-ov", "-format", "UDZO", "-volname",
        f"Balbis {version} · {edition}", "-srcfolder", str(stage), str(image))
    run("/usr/bin/hdiutil", "verify", str(image))
    digest = subprocess.check_output(["/usr/bin/shasum", "-a", "256", image.name], text=True, cwd=build)
    image.with_suffix(".dmg.sha256").write_text(digest)
    print(image)
PY
