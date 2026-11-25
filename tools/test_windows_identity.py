#!/usr/bin/env python3
"""Tests for tools/windows_identity.py on copies of the real runner files.

Run: python3 -I tools/test_windows_identity.py  (also covers verify-release.py windows)
"""
import importlib.util
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    "flutter/windows/CMakeLists.txt",
    "flutter/windows/runner/Runner.rc",
    "flutter/windows/runner/main.cpp",
]

spec = importlib.util.spec_from_file_location("windows_identity", ROOT / "tools/windows_identity.py")
windows_identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows_identity)


class WindowsIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        for rel in FILES:
            dest = self.tmp / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, dest)
        self.product = json.loads((ROOT / "config/build-lock.json").read_text())["product"]

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def read(self, rel):
        return (self.tmp / rel).read_text(encoding="utf-8")

    def test_runner_is_renamed_to_remote_hub(self):
        exe = windows_identity.apply(self.tmp, self.product["displayName"], self.product["appName"])
        self.assertEqual(exe, "RemoteHub.exe")

        cmake = self.read("flutter/windows/CMakeLists.txt")
        self.assertIn('set(BINARY_NAME "RemoteHub")', cmake)
        self.assertNotIn('"rustdesk"', cmake)

        rc = self.read("flutter/windows/runner/Runner.rc")
        values = dict(re.findall(r'VALUE "(\w+)", "([^"]*)" "\\0"', rc))
        self.assertEqual(values["ProductName"], "Remote Hub")
        self.assertEqual(values["FileDescription"], "Remote Hub")
        self.assertEqual(values["InternalName"], "RemoteHub")
        self.assertEqual(values["OriginalFilename"], "RemoteHub.exe")
        for key in ("ProductName", "FileDescription", "InternalName", "OriginalFilename",
                    "CompanyName"):
            self.assertNotIn("rustdesk", values[key].lower(), key)

        main = self.read("flutter/windows/runner/main.cpp")
        self.assertIn('std::wstring app_name = L"RemoteHub";', main)
        self.assertNotIn('L"RustDesk"', main)

    def test_upstream_runner_still_says_rustdesk(self):
        # The repository copy stays upstream; only staging is rewritten.
        self.assertIn('set(BINARY_NAME "rustdesk")',
                      (ROOT / "flutter/windows/CMakeLists.txt").read_text())

    def test_missing_upstream_line_fails_instead_of_skipping(self):
        path = self.tmp / "flutter/windows/CMakeLists.txt"
        path.write_text(path.read_text().replace('set(BINARY_NAME "rustdesk")', ""))
        with self.assertRaises(windows_identity.IdentityError):
            windows_identity.apply(self.tmp, "Remote Hub", "RemoteHub")

    def test_crlf_checkout_is_handled(self):
        for rel in FILES:
            p = self.tmp / rel
            p.write_bytes(p.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        self.assertEqual(windows_identity.apply(self.tmp, "Remote Hub", "RemoteHub"),
                         "RemoteHub.exe")
        self.assertIn('set(BINARY_NAME "RemoteHub")', self.read("flutter/windows/CMakeLists.txt"))


vspec = importlib.util.spec_from_file_location("verify_release", ROOT / "tools/verify-release.py")
verify_release = importlib.util.module_from_spec(vspec)
vspec.loader.exec_module(verify_release)


class VerifyWindowsTest(unittest.TestCase):
    """`verify-release.py windows` on synthetic Release directories."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.lock = json.loads((ROOT / "config/build-lock.json").read_text())
        engine = verify_release.FEATURE_MARKER + b"\0" + verify_release.APP_NAME_MARKER
        (self.tmp / "librustdesk.dll").write_bytes(engine)
        (self.tmp / "dylib_virtual_display.dll").write_bytes(b"MZ")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_checks(self):
        c = verify_release.Checker()
        verify_release.verify_windows(c, self.tmp, self.lock)
        return c.failed

    def test_remote_hub_executable_passes(self):
        u = verify_release.utf16
        (self.tmp / "RemoteHub.exe").write_bytes(
            b"MZ" + u("Remote Hub") + b"\0\0" + u("RemoteHub.exe"))
        self.assertEqual(self.run_checks(), 0)

    def test_missing_virtual_display_helper_fails(self):
        u = verify_release.utf16
        (self.tmp / "RemoteHub.exe").write_bytes(
            b"MZ" + u("Remote Hub") + b"\0\0" + u("RemoteHub.exe"))
        (self.tmp / "dylib_virtual_display.dll").unlink()
        self.assertGreater(self.run_checks(), 0)

    def test_unmodified_upstream_runner_fails(self):
        u = verify_release.utf16
        (self.tmp / "rustdesk.exe").write_bytes(
            b"MZ" + u("RustDesk Remote Desktop") + u("rustdesk.exe"))
        self.assertGreater(self.run_checks(), 0)

    def test_renamed_but_upstream_version_resource_fails(self):
        u = verify_release.utf16
        (self.tmp / "RemoteHub.exe").write_bytes(
            b"MZ" + u("RustDesk Remote Desktop") + u("rustdesk.exe"))
        self.assertGreater(self.run_checks(), 0)


class BuildWindowsScriptTest(unittest.TestCase):
    """tools/build-windows.ps1 cannot run here; check its step order statically."""

    def setUp(self):
        self.script = (ROOT / "tools/build-windows.ps1").read_text()

    def step_index(self, pattern):
        m = re.search(pattern, self.script)
        self.assertIsNotNone(m, pattern)
        return m.start()

    def test_virtual_display_helper_is_built_before_it_is_copied(self):
        build = self.step_index(r"cargo build[^\n]*-p dylib_virtual_display")
        copy = self.step_index(r"Copy-Item target\\release\\deps\\dylib_virtual_display\.dll")
        self.assertLess(build, copy)

    def test_helper_is_built_before_flutter_packaging(self):
        build = self.step_index(r"-p dylib_virtual_display")
        flutter = self.step_index(r"build windows --release")
        self.assertLess(build, flutter)


if __name__ == "__main__":
    unittest.main()
