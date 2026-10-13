#!/usr/bin/env python3
"""Exercise the native-hand gameinit composition and its real Lua callback."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
lua = shutil.which("luajit") or shutil.which("lua")
if not lua:
    raise SystemExit("Lua or LuaJIT is required to test the gameinit callback")
with tempfile.TemporaryDirectory(prefix="glovebox-hand-locomotion-") as scratch:
    executable = Path(scratch) / "test_hand_locomotion"
    subprocess.run([
        "xcrun", "swiftc", "-warnings-as-errors",
        str(root / "klepton/visionos/Sources/KleptonHandInput.swift"),
        str(root / "tools/tests/test_hand_locomotion.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), scratch], check=True)
    subprocess.run([lua, str(root / "tools/tests/test_hand_locomotion.lua"),
                    str(Path(scratch) / "cache/alyx-hands-gameinit.lua")], check=True)
