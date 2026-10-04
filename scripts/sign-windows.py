#!/usr/bin/env python3
"""Sign Oriel's app payload, rebuild its NSIS installer, then sign the installer."""
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

sdk = Path(os.environ["ProgramFiles(x86)"]) / "Windows Kits/10/bin"
signtool = str(sorted(sdk.glob("*/x64/signtool.exe"))[-1])
makensis = shutil.which("makensis") or str(Path(os.environ["ProgramFiles(x86)"]) / "NSIS/makensis.exe")
script = max(Path(".zig-cache").rglob("installer.nsi"), key=lambda p: p.stat().st_mtime)
text = script.read_text()
payload = re.search(r'^!define BINARY_SRC\s+"([^"]+)"', text, re.M)
installer = re.search(r'^!define OUT_FILE\s+"([^"]+)"', text, re.M)
if not payload or not installer:
    raise SystemExit("Could not resolve app and installer from Oriel's NSIS script")
with tempfile.TemporaryDirectory(prefix="ghostshare-sign-", dir=os.environ["RUNNER_TEMP"]) as temporary:
    certificate = Path(temporary) / "codesign.pfx"
    certificate.write_bytes(base64.b64decode(os.environ["ORIEL_WINDOWS_CERT_P12_BASE64"], validate=True))
    # Trust only on this disposable runner for self-signed chain verification.
    ps = "$c=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new($env:GHOSTFILE_CERT,$env:ORIEL_WINDOWS_CERT_PASSWORD); $s=[System.Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser'); $s.Open('ReadWrite'); $s.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($c.RawData)); $s.Close()"
    subprocess.run(["pwsh", "-NoProfile", "-Command", ps], env=dict(os.environ, GHOSTFILE_CERT=str(certificate)), check=True)
    def sign(path):
        result = subprocess.run([signtool, "sign", "/f", str(certificate), "/p", os.environ["ORIEL_WINDOWS_CERT_PASSWORD"], "/fd", "SHA256", "/tr", "https://timestamp.digicert.com", "/td", "SHA256", str(path)])
        if result.returncode: raise SystemExit("Code signing failed (exit " + str(result.returncode) + ")")
        subprocess.run([signtool, "verify", "/pa", str(path)], check=True)
    binary = Path(payload.group(1).replace("$$", "$"))
    sign(binary)
    shutil.copy2(binary, "zig-out/bin/ghostshare.exe")
    subprocess.run([makensis, "/NOCD", "/WX", str(script.resolve())], check=True)
    setup = Path(installer.group(1).replace("$$", "$"))
    sign(setup)
    shutil.copy2(setup, Path("zig-out/package") / setup.name)
