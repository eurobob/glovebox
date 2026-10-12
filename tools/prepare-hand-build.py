#!/usr/bin/env python3
"""Prepare the fork's Xcode project using a cached kit and game translations.

Does not download, install, or launch anything. Rebuilds the small OpenVR
hand-input shim when its source changes. --retranslate permits translating
cached Linux libraries into separate build output for a changed translator.
The signed upstream app is left intact as a rollback candidate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def kit_version(kit):
    metadata = json.loads((kit / "KIT.json").read_text())
    version = metadata.get("kit") if isinstance(metadata, dict) else None
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+)+", version):
        raise ValueError(f"Invalid kit version in {kit / 'KIT.json'}")
    return version


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


# These exact 0.1.1/0.1.5 release translators were compared byte-for-byte.
# The only differences are LC_UUID, the LC_CODE_SIGNATURE blob, and four
# N_OSO debug object paths/timestamps (klepton_ld, kl_x18, kl_env, kl_guestpatch).
# Masking those ten regions yields the same full-file SHA-256 on both:
# 228cfb27fad3aafc6efbdb0d1961e0fcc7d53267d0649d349e8cc52886d667dc.
# Every remaining byte, including bindings and non-debug symbols, is identical;
# translator inputs, mkguest and ldwrap sources also match v0.1.1/v0.1.5.
# This immutable pair is the sole exception; unknown builds must retranslate.
VERIFIED_EQUIVALENT_TRANSLATORS = frozenset({
    "83ad595398f0031af00ad621da0cfcf35c9f8084795568001986608198e9e0fb",
    "5e58e8f3fe7ca700d3faadc5e9b115975ab336ebf7c007dff7a1880380d3eb3c",
})


def translators_equivalent(first, second):
    a, b = digest(first), digest(second)
    return a == b or frozenset((a, b)) == VERIFIED_EQUIVALENT_TRANSLATORS


def translated_guest(root, kit):
    return root / "build/hand-controls" / f"guest-{kit_version(kit)}-{digest(kit / 'bin/klepton-ld')[:12]}"


def translation_inputs(root, cache):
    game = cache / "linux/game"
    runtime = json.loads((root / "packages/alyx/runtime-debs.json").read_text())
    required = [game / "bin/linuxsteamrtarm64/hlvr", game / "hlvr/bin/linuxsteamrtarm64",
                *[cache / "sysroot" / name for name in runtime["files"]]]
    for path in required:
        if not path.exists():
            raise ValueError(f"Missing cached Linux input {path}; retranslation does not download game data")
    candidates = sorted({*game.glob("bin/linuxsteamrtarm64/*.so*"),
                         *game.glob("hlvr/bin/linuxsteamrtarm64/*.so*"),
                         game / "bin/linuxsteamrtarm64/hlvr", *cache.glob("sysroot/*.so*")})
    inputs = []
    for path in candidates:
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as source:
                if source.read(4) == b"\x7fELF":
                    inputs.append(path)
    if not inputs or not any(path.parent == game / "hlvr/bin/linuxsteamrtarm64" for path in inputs):
        raise ValueError("Cached Linux game libraries are incomplete; cannot retranslate")
    return inputs


def cached_assets(root, home, kit_override=None, retranslate=False):
    """Validate cached inputs without changing the kit or any guest tree."""
    cache = home / "alyx"
    original_kit = cache / "kit"
    version = (root / "VERSION").read_text().strip()
    preferred = root / "build/hand-controls" / f"upstream-{version}" / "kit"
    if kit_override is not None:
        kit = kit_override.resolve()
    elif (preferred / "KIT.json").is_file() and kit_version(preferred) == version:
        kit = preferred
    else:
        kit = original_kit
    selected_version = kit_version(kit)
    if selected_version != version:
        raise ValueError(f"Source version {version} does not match kit {selected_version} at {kit}")

    guest = root / "klepton/visionos/build/glovebox-guest"
    source_guest = home / "source" / version / "klepton/visionos/build/glovebox-guest"
    replace_guest = None
    if not source_guest.exists():
        # Reuse only the existing link to the original installer's guest. A
        # byte-identical or verified equivalent translator permits reusing translations
        # with a newer runtime kit. A changed translator needs separate output.
        original_version = kit_version(original_kit)
        original_guest = home / "source" / original_version / "klepton/visionos/build/glovebox-guest"
        owned_guest = translated_guest(root, kit)
        if guest.is_symlink() and guest.resolve() == owned_guest.resolve():
            source_guest = owned_guest
        elif not guest.is_symlink() or guest.resolve() != original_guest.resolve():
            raise ValueError(f"Missing {source_guest}; no existing symlink to the original cached guest to reuse")
        elif translators_equivalent(kit / "bin/klepton-ld", original_kit / "bin/klepton-ld"):
            source_guest = original_guest
        elif retranslate:
            translation_inputs(root, cache)
            source_guest, replace_guest = owned_guest, original_guest
        else:
            raise ValueError("Selected kit translator differs from the original cached kit; "
                             "pass --retranslate to create separate guest output from cached Linux libraries")

    required = [cache / "pipelines.foz"]
    if source_guest != translated_guest(root, kit):
        required.append(source_guest / "libs.txt")
    for path in required:
        if not path.is_file():
            raise ValueError(f"Missing {path}. Complete the original Glovebox {version} Mac build first.")
    if (guest.is_symlink() or guest.exists()) and guest.resolve() != source_guest.resolve() and replace_guest is None:
        raise ValueError(f"Refusing to replace an existing guest tree at {guest}")
    return kit, cache, source_guest, replace_guest


def validate_translation(guest, names):
    actual = set((guest / "libs.txt").read_text().split())
    if actual != names:
        raise ValueError(f"Translated library list at {guest} does not match the cached Linux inputs")
    for name in names:
        framework = guest / f"{name}.xcframework/xros-arm64" / f"{name.replace('+', 'x')}.framework"
        for path in [framework / "Info.plist", framework / name.replace("+", "x")]:
            if not path.is_file() or path.stat().st_size == 0:
                raise ValueError(f"Incomplete translated guest: {path}")


def prepare_translation(root, kit, cache, output, b, emit, allow_retranslate):
    inputs = translation_inputs(root, cache)
    names = {path.name.split(".so")[0] for path in inputs}
    script = root / "klepton/visionos/mkguest_alyx.sh"
    wrapper = root / "klepton/tools/klepton_ldwrap.py"
    receipt = {"kit": kit_version(kit), "translator": digest(kit / "bin/klepton-ld"),
               "script": digest(script), "wrapper": digest(wrapper),
               "inputs": {str(path): digest(path) for path in inputs}}
    if output.is_symlink() or output.resolve() != output:
        raise ValueError(f"Refusing translation output redirected outside its owned path: {output}")
    if output.exists():
        if json.loads((output / ".hand-translation.json").read_text()) != receipt:
            raise ValueError(f"Existing owned guest {output} has different inputs; refusing to overwrite it")
        validate_translation(output, names)
        emit("step", step="translate", detail=f"{len(names)} matching cached guest libraries")
        return
    if not allow_retranslate:
        raise ValueError("Owned translated guest is missing; pass --retranslate to create it")
    work = root / "build/hand-controls"
    # mkguest's fixed relative raw cache stays inside this temporary harness.
    # Only the finished xcframeworks survive; cached input data is read-only.
    with tempfile.TemporaryDirectory(prefix="translate-", dir=work) as temporary:
        scratch = Path(temporary)
        links = {"linux": cache / "linux", "sysroot": cache / "sysroot",
                 "build/klepton-ld": kit / "bin/klepton-ld", "tools/klepton_ldwrap.py": wrapper,
                 "visionos/mkguest_alyx.sh": script}
        for relative, source in links.items():
            link = scratch / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(source, target_is_directory=source.is_dir())
        staged = scratch / "guest"
        previous = b.K, b.V, b.GUEST_DIR
        try:
            b.K, b.V, b.GUEST_DIR = str(scratch), str(scratch / "visionos"), str(staged)
            b.translate(str(scratch), emit)
            validate_translation(staged, names)
            (staged / ".hand-translation.json").write_text(json.dumps(receipt, indent=2) + "\n")
            staged.rename(output)
        finally:
            b.K, b.V, b.GUEST_DIR = previous
            log = scratch / "translate.log"
            if log.is_file():
                with log.open("rb") as source:
                    source.seek(max(0, log.stat().st_size - 1024 * 1024))
                    (work / "translate.log").write_bytes(source.read())


def link_guest(guest, source_guest, replace_guest=None):
    guest.parent.mkdir(parents=True, exist_ok=True)
    if guest.is_symlink() or guest.exists():
        if guest.resolve() == source_guest.resolve():
            return
        if not guest.is_symlink() or replace_guest is None or guest.resolve() != replace_guest.resolve():
            raise ValueError(f"Refusing to replace an existing guest tree at {guest}")
        # Replace the recognized old link atomically only after translation has
        # completed. A failed translation leaves the rollback guest selected.
        with tempfile.TemporaryDirectory(prefix="guest-link-", dir=guest.parent) as temporary:
            link = Path(temporary) / "guest"
            link.symlink_to(source_guest, target_is_directory=True)
            os.replace(link, guest)
    else:
        guest.symlink_to(source_guest, target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", required=True, help="The original install's Apple signing team")
    parser.add_argument("--build-number", help="Optional unique CFBundleVersion")
    parser.add_argument("--glovebox-home", type=Path,
                        default=Path.home() / "Library/Application Support/Glovebox")
    parser.add_argument("--kit", type=Path, help="Runtime kit directory matching the checkout VERSION")
    parser.add_argument("--retranslate", action="store_true",
                        help="Translate cached Linux inputs into owned output if the kit translator changed")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("--team must be a ten-character Apple team identifier")
    root = Path(__file__).resolve().parents[1]
    if shutil.disk_usage(root).free < 100 * 1024**3:
        parser.error("Less than 100 GiB free; do not start a device build")
    sys.path.insert(0, str(root / "engine"))
    from gb import build as b

    try:
        kit, cache, source_guest, replace_guest = cached_assets(
            root, args.glovebox_home.resolve(), args.kit, args.retranslate)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"Using runtime kit {kit}; cached guest {source_guest}")

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

    def emit(event, **kw):
        if event == "step":
            print(f"{kw.get('step')}: {kw.get('detail', '')}")

    b.kit(str(kit), str(work), emit)
    try:
        if source_guest == translated_guest(root, kit):
            prepare_translation(root, kit, cache, source_guest, b, emit, args.retranslate)
        link_guest(root / "klepton/visionos/build/glovebox-guest", source_guest, replace_guest)
    except (OSError, ValueError, b.StepError) as error:
        parser.error(str(error))
    subprocess.run([sys.executable, str(root / "tools/patch-hand-runtime.py"),
                    "--kit", str(kit), "--work", str(work)], check=True)
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
