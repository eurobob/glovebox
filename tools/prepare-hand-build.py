#!/usr/bin/env python3
"""Prepare the fork's Xcode project using the original installer's cached assets.

Does not download game data, build the runtime, install, or launch anything.
The signed upstream app is left intact as a rollback candidate.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", required=True, help="The original install's Apple signing team")
    parser.add_argument("--build-number", help="Optional unique CFBundleVersion")
    parser.add_argument("--glovebox-home", type=Path,
                        default=Path.home() / "Library/Application Support/Glovebox")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("--team must be a ten-character Apple team identifier")
    root = Path(__file__).resolve().parents[1]
    if shutil.disk_usage(root).free < 100 * 1024**3:
        parser.error("Less than 100 GiB free; do not start a device build")
    sys.path.insert(0, str(root / "engine"))
    from gb import build as b

    cache = args.glovebox_home.resolve() / "alyx"
    version = (root / "VERSION").read_text().strip()
    original = args.glovebox_home.resolve() / "source" / version
    source_guest = original / "klepton/visionos/build/glovebox-guest"
    required = [cache / "kit/KIT.json", cache / "pipelines.foz", source_guest / "libs.txt"]
    for path in required:
        if not path.is_file():
            parser.error(f"Missing {path}. Complete the original Glovebox {version} Mac build first.")

    work = root / "build/hand-controls"
    work.mkdir(parents=True, exist_ok=True)
    stamp_file = work / "build-stamp.txt"
    if args.build_number:
        stamp = args.build_number
    else:
        # A monotonically increasing three-part version, including repeated
        # builds in one minute. The source checkout keeps its own counter.
        serial = int(time.time() // 60)
        if stamp_file.exists():
            parts = stamp_file.read_text().strip().split(".")
            if len(parts) == 3 and all(p.isdigit() for p in parts):
                previous = int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])
                serial = max(serial, previous + 1)
        stamp = f"{serial // 10000}.{serial // 100 % 100}.{serial % 100}"
    if not re.fullmatch(r"\d+(\.\d+){0,2}", stamp):
        parser.error("--build-number must contain one to three numeric components")

    guest = root / "klepton/visionos/build/glovebox-guest"
    guest.parent.mkdir(parents=True, exist_ok=True)
    if guest.is_symlink() or guest.exists():
        if guest.resolve() != source_guest.resolve():
            parser.error(f"Refusing to replace an existing guest tree at {guest}")
    else:
        guest.symlink_to(source_guest, target_is_directory=True)

    def emit(event, **kw):
        if event == "step":
            print(f"{kw.get('step')}: {kw.get('detail', '')}")

    b.kit(str(cache / "kit"), str(work), emit)
    demo = b.defaults("alyx", str(work), str(cache / "pipelines.foz"), emit)
    env = dict(os.environ, KLEPTON_TEAM=args.team, KLEPTON_TARGET="alyx",
               KLEPTON_ALYX_DEMO=demo, KLEPTON_EVA="1",
               KLEPTON_ALYX_LAUNCHER=str(root / "launcher"),
               KLEPTON_DISPLAY_NAME="Glovebox: HLA", KLEPTON_BUILD_NUMBER=stamp,
               KLEPTON_INFOPLIST_SET=str(root / "packages/alyx/defaults/purpose-strings.plist"),
               KLEPTON_NO_HANDS="0", KLEPTON_GUEST_DIR="build/glovebox-guest",
               KLEPTON_BUNDLE_ID=b.bundle_id_for(args.team),
               KLEPTON_APPICON_DIR=str(root / "packages/alyx/icon"))
    subprocess.run([sys.executable, "gen_xcodeproj.py"], cwd=root / "klepton/visionos",
                   env=env, check=True)
    stamp_file.write_text(stamp + "\n")
    print(f"Prepared experimental hands build {stamp}; bundle {b.bundle_id_for(args.team)}")
    print("Build/install with visionos-cli-deploy --no-launch. Original signed app unchanged.")


if __name__ == "__main__":
    main()
