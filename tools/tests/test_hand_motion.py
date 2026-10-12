#!/usr/bin/env python3
"""Compile and run the standalone macOS motion tests, cleaning their binary."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="glovebox-hand-motion-") as scratch:
    executable = Path(scratch) / "test_hand_motion"
    subprocess.run([
        "xcrun", "swiftc", "-warnings-as-errors",
        str(root / "klepton/visionos/Sources/KleptonHandMotion.swift"),
        str(root / "tools/tests/test_hand_motion.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
