#!/usr/bin/env python3
"""Rewrite a staged AndroidManifest.xml into the controller-only Remote Hub
form (plan 16.1): no screen capture, accessibility, microphone, overlay or
boot services, no rustdesk:// deep link, and the Remote Hub label. Backup and
device-to-device transfer are disabled (plan 13.7): the credential vault is
ciphertext bound to this device's Keystore key, so restoring it elsewhere
would only yield unusable data. Permissions
that libraries would merge in (the upstream QR scanner's CAMERA) are removed
with tools:node="remove".

Usage: tools/android_controller_manifest.py <AndroidManifest.xml>
Only ever run on a staging copy (tools/build-android.sh does this).
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

A = "{http://schemas.android.com/apk/res/android}"
T = "{http://schemas.android.com/tools}"
REMOVED_PERMISSIONS = {
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.FOREGROUND_SERVICE_MICROPHONE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.RECORD_AUDIO",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
}
# Added by dependencies at manifest merge time, so they are removed explicitly.
MERGE_REMOVED_PERMISSIONS = {
    "android.permission.CAMERA",
}
# Android 12+ ignores allowBackup for device-to-device transfer; these rules
# exclude every domain from both cloud backup and device transfer.
DATA_EXTRACTION_RULES_NAME = "remote_hub_data_extraction_rules"
_DOMAINS = ("root", "file", "database", "sharedpref", "external")
DATA_EXTRACTION_RULES = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<data-extraction-rules>\n"
    + "".join(
        f"    <{section}>\n"
        + "".join(f'        <exclude domain="{d}" path="."/>\n' for d in _DOMAINS)
        + f"    </{section}>\n"
        for section in ("cloud-backup", "device-transfer"))
    + "</data-extraction-rules>\n"
)

REMOVED_COMPONENTS = {
    ".BootReceiver",
    ".InputService",
    ".MainService",
    ".FloatingWindowService",
    ".PermissionRequestTransparentActivity",
}


def main(path):
    ET.register_namespace("android", A[1:-1])
    ET.register_namespace("tools", "http://schemas.android.com/tools")
    tree = ET.parse(path)
    root = tree.getroot()
    for perm in list(root.findall("uses-permission")):
        if perm.get(A + "name") in REMOVED_PERMISSIONS:
            root.remove(perm)
    present = {p.get(A + "name") for p in root.findall("uses-permission")}
    for name in sorted(MERGE_REMOVED_PERMISSIONS - present):
        perm = ET.Element("uses-permission")
        perm.set(A + "name", name)
        perm.set(T + "node", "remove")
        root.insert(0, perm)
    app = root.find("application")
    app.set(A + "label", "Remote Hub")
    app.set(A + "allowBackup", "false")
    app.set(A + "fullBackupContent", "false")
    app.set(A + "dataExtractionRules", "@xml/" + DATA_EXTRACTION_RULES_NAME)
    # A library manifest that enables backup must not win the merge.
    app.set(T + "replace", ",".join(
        "android:" + a for a in ("allowBackup", "fullBackupContent", "dataExtractionRules")))
    rules = Path(path).parent / "res" / "xml" / (DATA_EXTRACTION_RULES_NAME + ".xml")
    rules.parent.mkdir(parents=True, exist_ok=True)
    rules.write_text(DATA_EXTRACTION_RULES, encoding="utf-8")
    for child in list(app):
        if child.get(A + "name") in REMOVED_COMPONENTS:
            app.remove(child)
    for activity in app.findall("activity"):
        for f in list(activity.findall("intent-filter")):
            if any(d.get(A + "scheme") == "rustdesk" for d in f.findall("data")):
                activity.remove(f)
    tree.write(path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main(sys.argv[1])
