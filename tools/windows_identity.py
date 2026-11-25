#!/usr/bin/env python3
"""Give a staged Windows runner the Remote Hub identity (plan RH-009): the
executable, its version resource and the window title name Remote Hub instead
of RustDesk, so the build is a separately identified product and never
collides with an installed RustDesk (`rustdesk.exe`, "RustDesk" window).

Usage: tools/windows_identity.py <staged source root>
Reads displayName/appName from config/build-lock.json. Only ever run on a
staging copy (tools/build-windows.ps1 does this). Exits 1 if an expected
upstream line is missing, so an upstream change cannot silently skip a step.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class IdentityError(Exception):
    pass


def _sub(path, pattern, replacement, text):
    new, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise IdentityError(f"{path}: expected one match for {pattern!r}, found {count}")
    return new


def _rc_value(key, value):
    # VALUE "Key", "value" "\0"
    return (rf'^(\s*VALUE "{key}", )"[^"]*"( "\\0")$', rf'\g<1>"{value}"\g<2>')


def apply(src, display_name, app_name):
    """Rewrites the runner files under `src`; returns the executable name."""
    exe = f"{app_name}.exe"
    edits = {
        "flutter/windows/CMakeLists.txt": [
            (r"^project\(rustdesk LANGUAGES CXX\)$", f"project({app_name} LANGUAGES CXX)"),
            (r'^set\(BINARY_NAME "rustdesk"\)$', f'set(BINARY_NAME "{app_name}")'),
        ],
        "flutter/windows/runner/Runner.rc": [
            _rc_value("CompanyName", f"{display_name} personal build"),
            _rc_value("FileDescription", display_name),
            _rc_value("InternalName", app_name),
            _rc_value("LegalCopyright",
                      "Based on RustDesk (AGPL-3.0), Copyright Purslane Tech Pte. Ltd."),
            _rc_value("OriginalFilename", exe),
            _rc_value("ProductName", display_name),
        ],
        # Window title / single-instance lookup before the engine reports
        # its APP_NAME.
        "flutter/windows/runner/main.cpp": [
            (r'^(\s*std::wstring app_name = )L"RustDesk";$', rf'\g<1>L"{app_name}";'),
        ],
    }
    for rel, subs in edits.items():
        path = Path(src, rel)
        text = path.read_text(encoding="utf-8")
        for pattern, replacement in subs:
            text = _sub(rel, pattern, replacement, text)
        path.write_text(text, encoding="utf-8")
    rc = Path(src, "flutter/windows/runner/Runner.rc").read_text(encoding="utf-8")
    if re.search(r'"(RustDesk|rustdesk|rustdesk\.exe)"', rc):
        raise IdentityError("Runner.rc still names RustDesk")
    return exe


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    lock = json.loads((ROOT / "config/build-lock.json").read_text())
    product = lock["product"]
    try:
        exe = apply(sys.argv[1], product["displayName"], product["appName"])
    except (IdentityError, OSError) as err:
        print(f"windows identity: {err}", file=sys.stderr)
        return 1
    print(f"windows identity: {product['displayName']} / {exe}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
