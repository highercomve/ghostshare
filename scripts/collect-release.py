#!/usr/bin/env python3
import hashlib
from pathlib import Path
import shutil
import sys
import tarfile

platform = sys.argv[1]
output = Path("dist")
output.mkdir(exist_ok=True)
roots = [Path("zig-out/package")] if platform != "android" else [Path("android/app/build/outputs/apk/release"), Path("android/app/build/outputs/bundle/release")]
count = 0
for root in roots:
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".deb", ".rpm", ".appimage", ".dmg", ".exe", ".apk", ".aab"}:
            shutil.copy2(path, output / f"ghostshare-{platform}-{path.name}")
            count += 1
# Updater payloads preserve the executable or the complete signed app bundle.
if platform in {"linux-x86_64", "windows-x86_64"}:
    suffix = ".exe" if platform.startswith("windows") else ""
    shutil.copy2(Path("zig-out/bin") / ("ghostshare" + suffix), output / (f"ghostshare-{platform}-update" + suffix))
elif platform == "macos-arm64":
    with tarfile.open(output / "ghostshare-macos-arm64-update.app.tar.gz", "w:gz") as archive:
        archive.add("zig-out/package/GhostShare.app", arcname="GhostShare.app")
if not count:
    raise SystemExit("No release packages found")
with (output / f"SHA256SUMS-{platform}").open("w") as checksums:
    for path in sorted(output.iterdir()):
        if path.name.startswith("SHA256SUMS") or not path.is_file(): continue
        checksums.write(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n")
print(f"Collected {count} {platform} packages")
