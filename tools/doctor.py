#!/usr/bin/env python3
"""Check the tools a Remote Hub build needs against config/build-lock.json.

Usage: tools/doctor.py --target {macos-arm64,android-arm64,windows-x64}

Read-only: it never installs or changes anything. Exit codes:
  0  every required tool is present at the pinned version
  1  something is missing or at a different version (listed on stderr)
  2  bad arguments or unreadable build lock

Environment: VCPKG_ROOT, RH_FLUTTER (flutter binary), RH_TOOLS (cargo root
with flutter_rust_bridge_codegen), ANDROID_NDK_HOME for Android. Windows runs
in a Visual Studio Developer shell, which sets VCToolsVersion,
WindowsSdkDir and WindowsSDKVersion.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return (out.stdout + out.stderr).strip()
    except (OSError, subprocess.TimeoutExpired):
        return None


def windows_toolchain(env, target, exists=os.path.exists, clang_version=""):
    """(ok, what) checks of MSVC, the Windows SDK and LLVM for windows-x64.

    The versions come from the Developer shell environment [env]. A version
    pinned in the build lock [target] must match exactly; an unpinned one
    (null until the first Windows build records it) must still be present.
    """
    checks = []
    msvc = env.get("VCToolsVersion", "").strip().rstrip("\\")
    pinned_msvc = target.get("msvc")
    if pinned_msvc:
        checks.append((msvc == pinned_msvc,
                       f"MSVC toolset {pinned_msvc} (VCToolsVersion, found {msvc or 'none'})"))
    else:
        checks.append((bool(msvc),
                       f"MSVC toolset (VCToolsVersion, found {msvc or 'none'}; "
                       "not pinned yet: record it in config/build-lock.json)"))

    sdk_dir = env.get("WindowsSdkDir", "").strip()
    sdk = env.get("WindowsSDKVersion", "").strip().rstrip("\\")
    pinned_sdk = target.get("windowsSdk")
    if pinned_sdk:
        checks.append((sdk == pinned_sdk,
                       f"Windows SDK {pinned_sdk} (WindowsSDKVersion, found {sdk or 'none'})"))
    else:
        checks.append((bool(sdk),
                       f"Windows SDK (WindowsSDKVersion, found {sdk or 'none'}; "
                       "not pinned yet: record it in config/build-lock.json)"))
    installed = bool(sdk_dir and sdk) and all(
        exists(os.path.join(sdk_dir, *part))
        for part in (("Include", sdk, "um", "windows.h"),
                     ("Lib", sdk, "um", "x64", "kernel32.lib")))
    checks.append((installed,
                   f"Windows SDK {sdk or '?'} headers and x64 libraries (WindowsSdkDir)"))

    llvm = target["llvm"]
    checks.append((f"version {llvm}" in clang_version, f"LLVM {llvm} (clang on PATH)"))
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True,
                        choices=["macos-arm64", "android-arm64", "windows-x64"])
    args = parser.parse_args()
    try:
        lock = json.loads((ROOT / "config/build-lock.json").read_text())
    except (OSError, ValueError) as e:
        print(f"cannot read build lock: {e}", file=sys.stderr)
        return 2
    target = lock["targets"][args.target]
    problems = []

    def need(ok, what):
        print(("ok      " if ok else "MISSING ") + what)
        if not ok:
            problems.append(what)

    head = run(["git", "-C", str(ROOT), "rev-parse", "HEAD"])
    print(f"info    repository HEAD {head}; pinned upstream {lock['upstream']['commit']}")
    for path, sha in lock["submodules"].items():
        status = run(["git", "-C", str(ROOT), "submodule", "status", path]) or ""
        need(sha in status and not status.startswith(("+", "-")),
             f"submodule {path} at {sha}")

    rust = target["rust"]
    rustc = run(["rustup", "run", rust, "rustc", "--version"]) or ""
    need(rustc.startswith(f"rustc {rust}"), f"Rust toolchain {rust}")

    flutter = os.environ.get("RH_FLUTTER", "flutter")
    fv = run([flutter, "--version"]) or ""
    need(f"Flutter {target['flutter']} " in fv, f"Flutter {target['flutter']} ({flutter})")

    vcpkg_root = os.environ.get("VCPKG_ROOT")
    vcpkg_head = run(["git", "-C", vcpkg_root, "rev-parse", "HEAD"]) if vcpkg_root else None
    need(vcpkg_head == lock["vcpkgCommit"], f"vcpkg at {lock['vcpkgCommit']} (VCPKG_ROOT)")
    triplet = target["vcpkgTriplet"]
    need(bool(vcpkg_root) and Path(vcpkg_root, "installed", triplet, "lib").is_dir(),
         f"vcpkg packages for {triplet}")

    tools = os.environ.get("RH_TOOLS", str(Path.home() / ".cargo"))
    codegen = Path(tools, "bin", "flutter_rust_bridge_codegen")
    gen = run([str(codegen), "--version"]) or ""
    need(lock["bridgeGenerator"]["flutter_rust_bridge_codegen"] in gen,
         f"flutter_rust_bridge_codegen {lock['bridgeGenerator']['flutter_rust_bridge_codegen']} ({codegen})")
    need(Path(tools, "bin", "cargo-expand").is_file(), "cargo-expand")

    if args.target == "macos-arm64":
        xc = run(["xcodebuild", "-version"]) or ""
        need("Xcode" in xc, "Xcode")
        nasm = run(["nasm", "-v"]) or ""
        need(lock["nasm"]["version"] in nasm, f"NASM {lock['nasm']['version']} on PATH")
        need(bool(shutil.which("gsed") or Path("/opt/homebrew/opt/gnu-sed/libexec/gnubin/sed").exists()),
             "GNU sed (for the Flutter 3.44 source patch)")
        need(bool(shutil.which("pod")), "CocoaPods")
    elif args.target == "android-arm64":
        ndk = os.environ.get("ANDROID_NDK_HOME", "")
        props = Path(ndk, "source.properties")
        need(props.is_file() and target["ndk"].split("(")[1].rstrip(")") in props.read_text(),
             f"Android NDK {target['ndk']} (ANDROID_NDK_HOME)")
        jv = run(["java", "-version"]) or ""
        need(f'version "{target["jdk"]}' in jv, f"JDK {target['jdk']}")
        cn = run(["cargo", "ndk", "--version"]) or ""
        need(target["cargoNdk"] in cn, f"cargo-ndk {target['cargoNdk']}")
    else:
        need(bool(shutil.which("cl")), "MSVC cl.exe on PATH")
        for ok, what in windows_toolchain(os.environ, target,
                                          clang_version=run(["clang", "--version"]) or ""):
            need(ok, what)

    if problems:
        print(f"\n{len(problems)} problem(s); nothing was changed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
