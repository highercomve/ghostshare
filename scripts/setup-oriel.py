#!/usr/bin/env python3
"""Install the pinned Oriel CLI, checking its release checksum."""
import hashlib
import os
from pathlib import Path
import platform
import urllib.request

VERSION = "v0.8.0"
arch = {"AMD64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}[platform.machine()]
system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}[platform.system()]
name = f"oriel-{arch}-{system}" + (".exe" if system == "windows" else "")
base = f"https://github.com/highercomve/Oriel/releases/download/{VERSION}"
checksums = urllib.request.urlopen(base + "/SHA256SUMS", timeout=60).read().decode()
expected = dict((line.split()[1].lstrip("*"), line.split()[0]) for line in checksums.splitlines())[name]
data = urllib.request.urlopen(base + "/" + name, timeout=120).read()
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit("Oriel checksum mismatch")
folder = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "ghostfile-oriel"
folder.mkdir(parents=True, exist_ok=True)
output = folder / ("oriel.exe" if system == "windows" else "oriel")
output.write_bytes(data)
output.chmod(0o755)
if os.environ.get("GITHUB_PATH"):
    with open(os.environ["GITHUB_PATH"], "a") as file:
        file.write(str(folder) + "\n")
print(f"Installed Oriel {VERSION} ({arch}-{system}); SHA-256 verified")
