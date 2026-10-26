#!/usr/bin/env python3
"""Package one host's Dart SDK compiler library and its private resources."""

import argparse
import hashlib
import json
import platform as host_platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def copy(source, destination, strip=None, kind=None):
    shutil.copyfile(source, destination)
    if kind == "macho":
        if sys.platform != "darwin":
            raise ValueError("Signing the macOS SDK requires macOS")
        subprocess.run(["/usr/bin/strip", "-x", str(destination)], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                        str(destination)], check=True)
    elif strip is not None:
        subprocess.run([str(strip), "--strip-unneeded", str(destination)], check=True)


def notices(sdk, clang):
    paths = [
        ("Dart", sdk / "LICENSE"),
        ("ICU", sdk / "third_party/icu/LICENSE"),
        ("BoringSSL", sdk / "third_party/boringssl/src/LICENSE"),
        ("zlib", sdk / "third_party/zlib/LICENSE"),
        ("double-conversion", sdk / "third_party/double-conversion/LICENSE"),
        ("cpu_features", sdk / "third_party/cpu_features/src/LICENSE"),
        ("libc++", sdk / "third_party/libcxx/LICENSE.TXT"),
        ("libc++abi", sdk / "third_party/libcxxabi/LICENSE.TXT"),
        ("Compiler runtime and libunwind", clang / "LICENSE"),
        ("Perfetto", sdk / "third_party/perfetto/src/LICENSE"),
    ]
    sections = []
    for name, path in paths:
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            raise ValueError(f"Empty notice: {path}")
        sections.append(f"{name}\n{'=' * 72}\n{text}\n")
    return "\n".join(sections)


def clang_directory(sdk, build_args):
    configured = re.search(r'clang_base_path\s*=\s*"([^"\n]+)"', build_args)
    if configured:
        path = configured[1]
        return sdk / path[2:] if path.startswith("//") else Path(path)
    os_name = {"linux": "linux", "darwin": "mac", "win32": "win"}[sys.platform]
    architecture = {"arm64": "arm64", "aarch64": "arm64",
                    "x86_64": "x64", "amd64": "x64"}[
                        host_platform.machine().lower()]
    if os_name == "win":
        architecture = "x64"
    return sdk / "buildtools" / f"{os_name}-{architecture}" / "clang"


def validate_image(source, kind, machine):
    with source.open("rb") as file:
        header = file.read(64)
        if kind == "elf":
            valid = (header[:7] == b"\x7fELF\x02\x01\x01" and
                     int.from_bytes(header[16:18], "little") == 3 and
                     int.from_bytes(header[18:20], "little") == machine)
        elif kind == "pe":
            valid = header[:2] == b"MZ" and len(header) == 64
            if valid:
                file.seek(int.from_bytes(header[60:64], "little"))
                pe = file.read(26)
                valid = (len(pe) == 26 and pe[:4] == b"PE\0\0" and
                         int.from_bytes(pe[4:6], "little") == machine and
                         int.from_bytes(pe[22:24], "little") & 0x2000 != 0 and
                         int.from_bytes(pe[24:26], "little") == 0x20B)
        elif kind == "macho":
            valid = (header[:4] == b"\xcf\xfa\xed\xfe" and
                     int.from_bytes(header[4:8], "little") == machine and
                     int.from_bytes(header[12:16], "little") == 6)
        else:
            raise ValueError(f"Unknown image format: {kind}")
    if not valid:
        raise ValueError(f"Expected {kind} image for machine {machine}: {source}")


def package(args):
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError(f"Output already exists: {output}")
    build_args = (args.build / "args.gn").read_text()
    for pattern in [r'is_product\s*=\s*true',
                    r'dart_runtime_mode\s*=\s*"profile"']:
        if re.search(pattern, build_args) is None:
            raise ValueError("Expected PRODUCT/profile build arguments")
    target_os = re.search(r'target_os\s*=\s*"([^"\n]+)"', build_args)
    target_cpu = re.search(r'target_cpu\s*=\s*"([^"\n]+)"', build_args)
    target = (target_os[1] if target_os else None,
              target_cpu[1] if target_cpu else None)
    if target == ("linux", "arm64"):
        platform, extension, prefix = "linux_arm64", "so", "lib"
        kind, machine, aot_machine = "elf", 183, 183
    elif target == ("win", "x64"):
        platform, extension, prefix = "windows_x64", "dll", ""
        kind, machine, aot_machine = "pe", 0x8664, 62
    elif target == ("mac", "arm64"):
        platform, extension, prefix = "macos_arm64", "dylib", "lib"
        kind, machine, aot_machine = "macho", 0x100000C, 183
    else:
        raise ValueError(f"No compiler archive format for {target}")
    clang = clang_directory(args.sdk, build_args)
    executable = ".exe" if sys.platform == "win32" else ""
    strip = clang / f"bin/llvm-strip{executable}"
    files = {
        f"compiler.{extension}": args.build / f"{prefix}compiler.{extension}",
        f"frontend.{extension}": args.build / f"{prefix}compiler_frontend.{extension}",
        f"backend.{extension}": args.build / f"{prefix}compiler_backend.{extension}",
        "frontend.aot": args.build / "frontend.aot",
        "runtime.node": args.runtime_dir / f"{prefix}napi_runtime.{extension}",
        "runtime-core.node": args.runtime_dir / f"{prefix}napi_runtime_core.{extension}",
        "runtime-regexp.node": args.runtime_dir / f"{prefix}napi_runtime_regexp.{extension}",
        "platform.dill": args.platform_dill,
    }
    for name, source in files.items():
        if name == "platform.dill":
            continue
        if name == "frontend.aot":
            validate_image(source, "elf", aot_machine)
        else:
            validate_image(source, kind, machine)
    license_text = (args.notices.read_text(encoding="utf-8")
                    if args.notices else notices(args.sdk, clang))
    if not license_text.strip():
        raise ValueError("The SDK notices must not be empty")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sdk-", dir=output.parent) as temp:
        staging = Path(temp) / platform
        staging.mkdir()
        for name, source in files.items():
            image = name not in {"platform.dill", "frontend.aot"}
            copy(source, staging / name, strip if image else None,
                 kind if image else None)
        (staging / "NOTICES").write_text(license_text, encoding="utf-8")
        entries = {
            file.name: {"size": file.stat().st_size,
                        "sha256": hashlib.sha256(file.read_bytes()).hexdigest()}
            for file in sorted(staging.iterdir()) if file.is_file()
        }
        sdk_version = (args.sdk / "tools/VERSION").read_text()
        version = ".".join(
            re.search(rf"^{name} (\d+)$", sdk_version, re.MULTILINE)[1]
            for name in ["MAJOR", "MINOR", "PATCH"]
        )
        revision = subprocess.check_output(
            ["git", "-C", str(args.sdk), "rev-parse", "HEAD"], text=True).strip()
        (staging / "manifest.json").write_text(
            json.dumps({"abi": 1, "platform": platform,
                        "dart": {"version": version, "revision": revision},
                        "files": entries}, indent=2) + "\n",
            encoding="utf-8")
        staging.rename(output)
    size = sum(file.stat().st_size for file in output.iterdir() if file.is_file())
    print(f"Packaged {platform}: {output} ({size} bytes)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["sdk", "build", "runtime-dir", "platform-dill", "output"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--notices", type=Path)
    args = parser.parse_args()
    try:
        package(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
