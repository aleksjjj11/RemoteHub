#!/usr/bin/env python3
"""Tests for the APK signature checks in tools/verify-release.py.

Run: python3 -I tools/test_verify_release.py
"""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("verify_release", ROOT / "tools/verify-release.py")
verify_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_release)

DEBUG = "V2 Signer: certificate DN: C=US, O=Android, CN=Android Debug\n"
OWNER = "Signer #1 certificate DN: CN=Owner, O=Personal\n"


def failures(returncode, output, release):
    c = verify_release.Checker()
    verify_release.check_apk_signers(c, returncode, output, release)
    return c.failed


class ApkSignatureTest(unittest.TestCase):
    def test_release_rejects_debug_or_missing_signature(self):
        self.assertGreater(failures(0, DEBUG, release=True), 0)
        self.assertGreater(failures(1, "", release=True), 0)
        self.assertEqual(failures(0, OWNER, release=True), 0)

    def test_debug_build_accepts_the_debug_key(self):
        self.assertEqual(failures(0, DEBUG, release=False), 0)


if __name__ == "__main__":
    unittest.main()
