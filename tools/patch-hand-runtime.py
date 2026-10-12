#!/usr/bin/env python3
"""Replace the staged device OpenVR object; preserve the original runtime kit.

Only the OpenVR shim is compiled. Its weak native hand bridge is linked by the
app, so this does not rebuild Klepton, LuaJIT, graphics dependencies or game code.
Run after gb.build.kit(), which restores the original staged archives each time.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


SLICE = Path("xros-arm64")
ARCHIVE = Path("Frameworks/KleptonAlyx.xcframework") / SLICE / "libKleptonAlyx.a"
MEMBER = "klvr_all.o"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def output(command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()


def vulkan_headers(explicit, root):
    candidates = [explicit] if explicit else [
        root / "klepton/vendor-moltenvk/out/include",
        Path("/opt/homebrew/opt/vulkan-headers/include"),
        Path("/usr/local/opt/vulkan-headers/include"),
    ]
    for candidate in candidates:
        if candidate and (candidate / "vulkan/vulkan.h").is_file():
            return candidate.resolve()
    raise RuntimeError("Vulkan headers missing; pass --vulkan-include pointing to their include directory")


def patch(root, kit, work, vulkan_include=None):
    kit, work = kit.resolve(), work.resolve()
    source = root / "klepton"
    shim = source / "runtime/openvr"
    base = kit / ARCHIVE
    staged = source / "visionos" / ARCHIVE
    metadata = json.loads((kit / "KIT.json").read_text())
    version = (root / "VERSION").read_text().strip()
    if metadata.get("kit") != version:
        raise RuntimeError(f"Source version {version} does not match kit {metadata.get('kit')}")
    # The kit's original upstream commit is not necessarily in this fork's Git
    # history. Compare the actual ABI headers the replacement platform consumes.
    headers = kit / "Klepton.xcframework" / SLICE / "Headers"
    for relative in ["xr/kl_ovrp.h", "gfx/kl_vulkan.h"]:
        if (source / "runtime" / relative).read_bytes() != (headers / relative).read_bytes():
            raise RuntimeError(f"Kit/source ABI mismatch: {relative}; refusing an archive overlay")
    if not base.is_file() or not staged.is_file():
        raise RuntimeError("Original or staged Alyx archive missing; stage the kit before patching")
    if staged.is_symlink() or not staged.resolve().is_relative_to(root.resolve()) or staged.samefile(base):
        raise RuntimeError("The staged archive must be a separate file inside this checkout")
    members = output(["xcrun", "ar", "-t", str(base)]).splitlines()
    if members.count(MEMBER) != 1:
        raise RuntimeError(f"Expected exactly one {MEMBER} in the original Alyx archive")

    include = vulkan_headers(vulkan_include, root)
    sdk = Path(output(["xcrun", "--sdk", "xros", "--show-sdk-path"]))
    clang = output(["xcrun", "--sdk", "xros", "--find", "clang"])
    clangxx = output(["xcrun", "--sdk", "xros", "--find", "clang++"])
    common = ["-g", "-O1", "-arch", "arm64", "-target", "arm64-apple-xros1.0",
              "-isysroot", str(sdk), "-Wall", "-Wno-unused-parameter",
              f"-ffile-prefix-map={root}/=glovebox/"]
    cxx_flags = common + ["-std=c++17", "-fvisibility=hidden", "-DVR_API_EXPORT",
                         "-I" + str(shim / "src"), "-iquote", str(shim / "third_party/openvr"),
                         "-isystem", str(include)]
    runtime_dirs = ["", "jni", "libc", "gfx", "xr", "media", "guest", "diag", "linux"]
    c_flags = common + ["-Wextra", "-I" + str(shim / "src")]
    c_flags += ["-I" + str(source / "runtime" / directory) for directory in runtime_dirs]
    cpp = sorted((shim / "src").glob("klvr_*.cpp"))
    platform = shim / "platform/klvr_platform_klepton.c"
    if not cpp:
        raise RuntimeError("No OpenVR sources found")

    # Hash all shim/generated headers plus runtime ABI headers. This includes
    # the new native bridge declaration without compiling its app-owned source.
    dependencies = set(cpp + [platform, Path(__file__).resolve(), kit / "KIT.json"])
    dependencies.update((shim / "src").rglob("*.h"))
    dependencies.update((shim / "src").rglob("*.inc"))
    dependencies.update((shim / "third_party/openvr").glob("*.h"))
    dependencies.update((source / "runtime").glob("*.h"))
    dependencies.update((source / "runtime").glob("*/*.h"))
    for directory in ["vulkan", "vk_video"]:
        dependencies.update((include / directory).rglob("*.h"))
    for name in ["SDKSettings.json", "SDKSettings.plist"]:
        if (sdk / name).is_file():
            dependencies.add(sdk / name)
    config = {"compiler": output([clangxx, "--version"]), "sdk": str(sdk),
              "c_flags": c_flags, "cxx_flags": cxx_flags, "kit_archive": digest(base),
              "inputs": {str(path): digest(path) for path in sorted(dependencies)}}
    fingerprint = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    cache = work / "runtime-shim-cache"
    cache.mkdir(parents=True, exist_ok=True)
    cached_object, receipt = cache / MEMBER, cache / "receipt.json"
    try:
        prior = json.loads(receipt.read_text())
        warm = prior["fingerprint"] == fingerprint and prior["object_sha256"] == digest(cached_object)
    except (OSError, ValueError, KeyError):
        warm = False

    if not warm:
        if shutil.disk_usage(work).free < 100 * 1024**3:
            raise RuntimeError("Less than 100 GiB free; do not start a device compilation")
        print(f"runtime: compiling {len(cpp)} OpenVR sources and platform for arm64 xros", flush=True)
        log = cache / "compile.log"
        with tempfile.TemporaryDirectory(prefix="compile-", dir=cache) as scratch_name:
            scratch = Path(scratch_name)
            objects = []
            with log.open("w") as transcript:
                def compile_one(command):
                    result = subprocess.run(command, stdout=transcript, stderr=subprocess.STDOUT)
                    if result.returncode:
                        raise RuntimeError(f"OpenVR compile/link failed; inspect {log}")
                for path in cpp:
                    obj = scratch / (path.stem + ".o")
                    compile_one([clangxx, *cxx_flags, "-c", str(path), "-o", str(obj)])
                    objects.append(obj)
                obj = scratch / "klvr_platform_klepton.o"
                compile_one([clang, *c_flags, "-c", str(platform), "-o", str(obj)])
                objects.append(obj)
                combined = scratch / MEMBER
                # Keep the shim together: registry weak stubs must not prevent
                # the archive linker from pulling in the real implementations.
                compile_one(["xcrun", "ld", "-r", "-arch", "arm64", "-o", str(combined),
                             *map(str, objects)])
            if ({str(path): digest(path) for path in sorted(dependencies)} != config["inputs"]
                    or sorted((shim / "src").glob("klvr_*.cpp")) != cpp):
                raise RuntimeError("OpenVR inputs changed during compilation; rerun preparation")
            os.replace(combined, cached_object)
        receipt.write_text(json.dumps({"fingerprint": fingerprint,
                                       "object_sha256": digest(cached_object),
                                       "configuration": config}, indent=2) + "\n")
    else:
        print(f"runtime: reusing cached OpenVR object {fingerprint[:12]}", flush=True)

    # Rebase on the pristine cached kit every time. A second invocation is
    # idempotent and cannot accumulate duplicate archive members.
    with tempfile.TemporaryDirectory(prefix="patch-", dir=staged.parent) as scratch_name:
        candidate = Path(scratch_name) / staged.name
        shutil.copyfile(base, candidate)
        subprocess.run(["xcrun", "ar", "-rcs", str(candidate), str(cached_object)], check=True)
        patched_members = output(["xcrun", "ar", "-t", str(candidate)]).splitlines()
        if patched_members != members:
            raise RuntimeError("Patched archive member list differs from original")
        os.replace(candidate, staged)
    print(f"runtime: staged {MEMBER}, archive sha256 {digest(staged)[:16]}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", required=True, type=Path, help="Original cached kit directory")
    parser.add_argument("--work", type=Path, help="Build workspace for the bounded warm object cache")
    parser.add_argument("--vulkan-include", type=Path, help="Existing Vulkan header include directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        patch(root, args.kit, args.work or root / "build/hand-controls", args.vulkan_include)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"runtime: {error}\n")


if __name__ == "__main__":
    main()
