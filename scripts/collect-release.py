#!/usr/bin/env python3
import hashlib
from pathlib import Path
import shutil
import sys

platform = sys.argv[1]
output = Path("dist")
output.mkdir(exist_ok=True)
roots = [Path("zig-out/package")] if platform != "android" else [Path("android/app/build/outputs/apk/release"), Path("android/app/build/outputs/bundle/release")]
count = 0
for root in roots:
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".deb", ".rpm", ".appimage", ".dmg", ".exe", ".apk", ".aab"}:
            shutil.copy2(path, output / f"ghostfile-{platform}-{path.name}")
            count += 1
if not count:
    raise SystemExit("No release packages found")
with (output / f"SHA256SUMS-{platform}").open("w") as checksums:
    for path in sorted(output.iterdir()):
        if path.name.startswith("SHA256SUMS") or not path.is_file(): continue
        checksums.write(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n")
print(f"Collected {count} {platform} packages")
