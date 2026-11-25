#!/usr/bin/env python3
"""Check a built Remote Hub artifact before it is handed to the owner.

Usage:
  tools/verify-release.py macos <Remote Hub.app> [--commit SHA] [--release]
  tools/verify-release.py apk <file.apk> [--commit SHA] [--release]
  tools/verify-release.py windows <Release dir> [--commit SHA] [--release]
  tools/verify-release.py manifest <artifacts-dir> --version V --commit SHA

Checks (macos/apk):
  * with --release (and always for `manifest`) --commit must be a full clean
    commit SHA, never a "-dirty" label from tools/source_state.py;
  * the native engine library is present;
  * it was built with the `remote_hub` feature (its network-deny marker is in
    the binary) and identifies as the Remote Hub product;
  * no test-only material (the in-memory test CA name) is in the binary;
  * macOS: bundle id matches config/build-lock.json, no URL scheme,
    signature verifies;
  * APK: application id matches the build lock and the merged manifest asks
    for none of the host-side or unneeded permissions (needs aapt2 from
    $ANDROID_HOME/build-tools); apksigner verifies the signature, and with
    --release the signer must not be the Android debug key;
  * Windows: the executable is <appName>.exe from the build lock, there is no
    rustdesk.exe, and its version resource names Remote Hub, not RustDesk;
  * prints SHA-256 of every checked file.
`manifest` writes release-manifest.json and SHA256SUMS for the files in a
directory; it refuses empty files.

Exit codes: 0 all checks passed, 1 a check failed, 2 bad arguments.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEATURE_MARKER = b"Remote Hub: RustDesk servers, relays, updates and LAN discovery are disabled"
APP_NAME_MARKER = b"RemoteHub"
TEST_ONLY_MARKERS = [b"Remote Hub test CA"]
# A controller never captures, records, overlays or starts itself.
FORBIDDEN_APK_PERMISSIONS = {
    "android.permission.CAMERA",
    "android.permission.RECORD_AUDIO",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.FOREGROUND_SERVICE_MICROPHONE",
    "android.permission.BIND_ACCESSIBILITY_SERVICE",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Checker:
    def __init__(self):
        self.failed = 0

    def check(self, ok, what):
        print(("PASS " if ok else "FAIL ") + what)
        if not ok:
            self.failed += 1

    def engine(self, name, data):
        self.check(FEATURE_MARKER in data, f"{name}: built with the remote_hub feature")
        self.check(APP_NAME_MARKER in data, f"{name}: Remote Hub app identity compiled in")
        for marker in TEST_ONLY_MARKERS:
            self.check(marker not in data, f"{name}: no test-only marker {marker.decode()!r}")
        print(f"sha256 {sha256(data)}  {name}")


def verify_macos(c, app, lock):
    lib = app / "Contents/Frameworks/liblibrustdesk.dylib"
    c.check(lib.is_file(), "engine library Contents/Frameworks/liblibrustdesk.dylib present")
    if lib.is_file():
        c.engine(lib.name, lib.read_bytes())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    want = lock["product"]["macosBundleId"]
    c.check(info.get("CFBundleIdentifier") == want,
            f"bundle id {info.get('CFBundleIdentifier')} == {want}")
    c.check(not info.get("CFBundleURLTypes"), "no URL scheme (rustdesk://) registered")
    exe = app / "Contents/MacOS" / info.get("CFBundleExecutable", "")
    c.check(exe.is_file(), f"main executable {exe.name} present")
    if exe.is_file():
        print(f"sha256 {sha256(exe.read_bytes())}  {exe.name}")
    sig = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                         capture_output=True, text=True)
    c.check(sig.returncode == 0, "codesign --verify --deep --strict" +
            ("" if sig.returncode == 0 else f": {sig.stderr.strip()}"))


def find_aapt2():
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        return None
    tools = sorted(Path(sdk, "build-tools").glob("*/aapt2"))
    return tools[-1] if tools else None


def find_apksigner():
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        return None
    tools = sorted(Path(sdk, "build-tools").glob("*/apksigner"))
    return tools[-1] if tools else None


def check_apk_signers(c, returncode, output, release):
    """Judges `apksigner verify --print-certs` output."""
    c.check(returncode == 0, "apksigner verify: APK signature valid")
    signers = re.findall(r"^(?:V\d+ )?Signer(?: #\d+)?:? certificate DN: (.*)$", output, re.MULTILINE)
    c.check(bool(signers), "APK names a signer certificate")
    if release:
        c.check(bool(signers) and not any("CN=Android Debug" in s for s in signers),
                "release APK signed with the owner's key, not the debug key")


def verify_apk_signature(c, apk, release):
    apksigner = find_apksigner()
    c.check(apksigner is not None, "apksigner found (ANDROID_HOME/build-tools)")
    if apksigner is None:
        return
    out = subprocess.run([str(apksigner), "verify", "--print-certs", str(apk)],
                         capture_output=True, text=True)
    check_apk_signers(c, out.returncode, out.stdout, release)


def verify_apk_manifest(c, apk, lock):
    aapt2 = find_aapt2()
    c.check(aapt2 is not None, "aapt2 found (ANDROID_HOME/build-tools)")
    if aapt2 is None:
        return
    out = subprocess.run([str(aapt2), "dump", "badging", str(apk)],
                         capture_output=True, text=True)
    c.check(out.returncode == 0, "aapt2 read the APK manifest")
    package = ""
    permissions = set()
    for line in out.stdout.splitlines():
        if line.startswith("package: name='"):
            package = line.split("'")[1]
        elif line.startswith("uses-permission: name='"):
            permissions.add(line.split("'")[1])
    expected = lock["product"]["androidApplicationId"]
    c.check(package == expected, f"application id {package!r} == {expected!r}")
    for perm in sorted(FORBIDDEN_APK_PERMISSIONS & permissions):
        c.check(False, f"no {perm}")
    c.check(not FORBIDDEN_APK_PERMISSIONS & permissions,
            "no host-side or unneeded permissions")


def verify_apk(c, apk, lock, release=False):
    verify_apk_manifest(c, apk, lock)
    verify_apk_signature(c, apk, release)
    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())
        lib = "lib/arm64-v8a/librustdesk.so"
        c.check(lib in names, f"{lib} present")
        c.check("lib/arm64-v8a/libc++_shared.so" in names, "libc++_shared.so present")
        c.check(not any(n.startswith(("lib/armeabi", "lib/x86")) for n in names),
                "arm64-only APK")
        if lib in names:
            c.engine("librustdesk.so", z.read(lib))
    print(f"sha256 {sha256(Path(apk).read_bytes())}  {Path(apk).name}")


def utf16(text):
    return text.encode("utf-16-le")


def verify_windows(c, release, lock):
    product = lock["product"]
    exe = Path(release, f"{product['appName']}.exe")
    c.check(exe.is_file(), f"executable {exe.name} present")
    c.check(not Path(release, "rustdesk.exe").exists(), "no rustdesk.exe")
    if exe.is_file():
        data = exe.read_bytes()
        # Version resource strings are UTF-16LE.
        c.check(utf16(product["displayName"]) in data,
                f"version resource names {product['displayName']!r}")
        c.check(utf16(exe.name) in data, f"OriginalFilename is {exe.name}")
        for upstream in ("RustDesk Remote Desktop", "rustdesk.exe"):
            c.check(utf16(upstream) not in data, f"no upstream identity {upstream!r}")
        print(f"sha256 {sha256(data)}  {exe.name}")
    c.check(Path(release, "dylib_virtual_display.dll").is_file(),
            "virtual display helper dylib_virtual_display.dll present")
    lib = Path(release, "librustdesk.dll")
    c.check(lib.is_file(), "engine library librustdesk.dll present")
    if lib.is_file():
        c.engine(lib.name, lib.read_bytes())


def check_source_commit(c, commit, release):
    """A release names the full commit it was built from; a "-dirty" label
    (tools/source_state.py --allow-dirty) marks sources no commit holds."""
    clean = bool(commit) and re.fullmatch(r"[0-9a-f]{40}", commit) is not None
    if release:
        c.check(clean, f"release source is a clean commit (got {commit!r})")
    elif commit and not clean:
        print(f"note: source {commit} is not a clean commit; test build only")


def write_manifest(c, directory, version, commit):
    files = sorted(p for p in Path(directory).iterdir()
                   if p.is_file() and p.name not in ("SHA256SUMS", "release-manifest.json"))
    for p in files:
        c.check(p.stat().st_size > 0, f"{p.name} is not empty")
    if c.failed:
        return
    sums = {p.name: sha256(p.read_bytes()) for p in files}
    Path(directory, "SHA256SUMS").write_text(
        "".join(f"{h}  {n}\n" for n, h in sums.items()))
    Path(directory, "release-manifest.json").write_text(json.dumps({
        "product": "Remote Hub",
        "version": version,
        "sourceCommit": commit,
        "files": sums,
    }, indent=2) + "\n")
    print(f"wrote SHA256SUMS and release-manifest.json for {len(files)} file(s)")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("kind", choices=["macos", "apk", "windows", "manifest"])
    p.add_argument("path")
    p.add_argument("--commit")
    p.add_argument("--version")
    p.add_argument("--release", action="store_true",
                   help="require a clean source commit; apk: and a signer other "
                        "than the Android debug key")
    a = p.parse_args()
    lock = json.loads((ROOT / "config/build-lock.json").read_text())
    c = Checker()
    path = Path(a.path)
    if not path.exists():
        print(f"{path} does not exist", file=sys.stderr)
        return 2
    if a.commit:
        print(f"source commit {a.commit}; pinned upstream {lock['upstream']['commit']}")
    # A manifest is only written for a release.
    check_source_commit(c, a.commit, a.release or a.kind == "manifest")
    if a.kind == "macos":
        verify_macos(c, path, lock)
    elif a.kind == "apk":
        verify_apk(c, path, lock, a.release)
    elif a.kind == "windows":
        verify_windows(c, path, lock)
    else:
        if not (a.version and a.commit):
            print("manifest needs --version and --commit", file=sys.stderr)
            return 2
        write_manifest(c, path, a.version, a.commit)
    print(f"{c.failed} check(s) failed")
    return 1 if c.failed else 0


if __name__ == "__main__":
    sys.exit(main())
