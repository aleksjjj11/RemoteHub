#!/usr/bin/env python3
"""Tests for tools/android_controller_manifest.py on a copy of the real manifest.

Run: python3 -I tools/test_android_controller_manifest.py
"""
import importlib.util
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = "flutter/android/app/src/main/AndroidManifest.xml"
A = "{http://schemas.android.com/apk/res/android}"
T = "{http://schemas.android.com/tools}"

spec = importlib.util.spec_from_file_location(
    "android_controller_manifest", ROOT / "tools/android_controller_manifest.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ControllerManifestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.path = self.tmp / "main" / "AndroidManifest.xml"
        self.path.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / MANIFEST, self.path)
        mod.main(str(self.path))
        self.app = ET.parse(self.path).getroot().find("application")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_label_is_remote_hub(self):
        self.assertEqual(self.app.get(A + "label"), "Remote Hub")

    def test_backup_is_disabled(self):
        self.assertEqual(self.app.get(A + "allowBackup"), "false")
        self.assertEqual(self.app.get(A + "fullBackupContent"), "false")
        self.assertIn("android:allowBackup", self.app.get(T + "replace"))

    def test_data_extraction_rules_exclude_cloud_and_device_transfer(self):
        ref = self.app.get(A + "dataExtractionRules")
        self.assertEqual(ref, "@xml/" + mod.DATA_EXTRACTION_RULES_NAME)
        rules = self.path.parent / "res" / "xml" / (mod.DATA_EXTRACTION_RULES_NAME + ".xml")
        root = ET.parse(rules).getroot()
        self.assertEqual(root.tag, "data-extraction-rules")
        for section in ("cloud-backup", "device-transfer"):
            node = root.find(section)
            self.assertIsNotNone(node, section)
            excluded = {e.get("domain") for e in node.findall("exclude")}
            self.assertTrue({"sharedpref", "file", "database", "root"} <= excluded, section)
            self.assertEqual(node.findall("include"), [])

    def test_host_components_are_removed(self):
        names = {c.get(A + "name") for c in self.app}
        self.assertFalse(names & mod.REMOVED_COMPONENTS)

    def test_repository_manifest_is_untouched(self):
        self.assertNotIn("allowBackup", (ROOT / MANIFEST).read_text())


if __name__ == "__main__":
    unittest.main()
