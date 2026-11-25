#!/usr/bin/env python3
"""Tests for the Windows toolchain checks of tools/doctor.py (plan 25.1).

Run: python3 -I tools/test_doctor.py
"""
import importlib.util
import json
import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location("doctor", ROOT / "tools/doctor.py")
doctor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doctor)

SDK_DIR = os.path.join("C:", "Program Files (x86)", "Windows Kits", "10")
SDK = "10.0.22621.0"
SHELL = {
    "VCToolsVersion": "14.40.33807\\",
    "WindowsSdkDir": SDK_DIR,
    # The Developer shell ends the SDK version with a backslash.
    "WindowsSDKVersion": SDK + "\\",
}
CLANG = "clang version 15.0.6\nTarget: x86_64-pc-windows-msvc"


def installed(sdk=SDK):
    files = {
        os.path.join(SDK_DIR, "Include", sdk, "um", "windows.h"),
        os.path.join(SDK_DIR, "Lib", sdk, "um", "x64", "kernel32.lib"),
    }
    return files.__contains__


def target(**pins):
    t = {"llvm": "15.0.6", "msvc": None, "windowsSdk": None}
    t.update(pins)
    return t


def failed(checks):
    return [what for ok, what in checks if not ok]


class WindowsToolchainTest(unittest.TestCase):
    def test_a_complete_developer_shell_passes_while_unpinned(self):
        checks = doctor.windows_toolchain(SHELL, target(), installed(), CLANG)
        self.assertEqual(failed(checks), [])
        self.assertTrue(any("not pinned yet" in what for _, what in checks))

    def test_no_windows_sdk_fails(self):
        env = {"VCToolsVersion": "14.40.33807"}
        problems = failed(doctor.windows_toolchain(env, target(), installed(), CLANG))
        self.assertTrue(any(p.startswith("Windows SDK (") for p in problems), problems)
        self.assertTrue(any("headers and x64 libraries" in p for p in problems), problems)

    def test_a_named_sdk_without_its_files_fails(self):
        problems = failed(doctor.windows_toolchain(SHELL, target(), lambda _: False, CLANG))
        self.assertEqual(problems,
                         [f"Windows SDK {SDK} headers and x64 libraries (WindowsSdkDir)"])

    def test_pinned_versions_must_match_exactly(self):
        pins = target(msvc="14.40.33807", windowsSdk=SDK)
        self.assertEqual(failed(doctor.windows_toolchain(SHELL, pins, installed(), CLANG)), [])

        other = dict(SHELL, WindowsSDKVersion="10.0.26100.0\\",
                     VCToolsVersion="14.42.34433")
        problems = failed(doctor.windows_toolchain(
            other, pins, installed("10.0.26100.0"), CLANG))
        self.assertEqual(problems, [
            "MSVC toolset 14.40.33807 (VCToolsVersion, found 14.42.34433)",
            f"Windows SDK {SDK} (WindowsSDKVersion, found 10.0.26100.0)",
        ])

    def test_llvm_must_be_the_pinned_version(self):
        problems = failed(doctor.windows_toolchain(
            SHELL, target(), installed(), "clang version 18.1.8"))
        self.assertEqual(problems, ["LLVM 15.0.6 (clang on PATH)"])
        problems = failed(doctor.windows_toolchain(SHELL, target(), installed(), ""))
        self.assertEqual(problems, ["LLVM 15.0.6 (clang on PATH)"])

    def test_the_build_lock_has_the_windows_pin_fields(self):
        lock = json.loads((ROOT / "config/build-lock.json").read_text())
        windows = lock["targets"]["windows-x64"]
        for key in ("msvc", "windowsSdk", "llvm"):
            self.assertIn(key, windows)


if __name__ == "__main__":
    unittest.main()
