#!/usr/bin/env python3
"""Build the CLI from the same development checkout as the app framework."""
import os
from pathlib import Path
import subprocess

framework = Path("../oriel-ghostshare").resolve()
if not (framework / "build.zig").is_file():
    raise SystemExit("Oriel development checkout is required at ../oriel-ghostshare")
revision = subprocess.check_output(["git", "-C", str(framework), "rev-parse", "HEAD"], text=True).strip()
expected = os.environ.get("ORIEL_REF")
if expected:
    requested = subprocess.check_output(["git", "-C", str(framework), "rev-parse", expected + "^{commit}"], text=True).strip()
    if revision != requested:
        raise SystemExit("Oriel checkout does not match the requested CI revision")
subprocess.run(["zig", "build", "cli", "-Doptimize=ReleaseSafe"], cwd=framework, check=True)
folder = framework / "zig-out/bin"
if os.environ.get("GITHUB_PATH"):
    with open(os.environ["GITHUB_PATH"], "a") as file:
        file.write(str(folder) + "\n")
print("Built Oriel development CLI from " + revision)
