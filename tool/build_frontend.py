#!/usr/bin/env python3
"""Build the SDK's private Dart frontend as an ELF AOT snapshot."""

import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
for name in ["sdk", "packages", "entry", "output"]:
    parser.add_argument("--" + name, required=True)
parser.add_argument("--target-os", choices=["linux", "macos", "windows"])
parser.add_argument("--gen-snapshot")
args = parser.parse_args()
sdk = Path(args.sdk)
output = Path(args.output)
kernel = output.with_suffix(".dill")
output.parent.mkdir(parents=True, exist_ok=True)
suffix = ".exe" if sys.platform == "win32" else ""
target = args.target_os or (
    "macos" if sys.platform == "darwin" else "windows" if suffix else "linux")
generator = args.gen_snapshot or str(sdk / ("bin/utils/gen_snapshot" + suffix))
subprocess.run([
    str(sdk / ("bin/dartaotruntime" + suffix)),
    str(sdk / "bin/snapshots/gen_kernel_aot.dart.snapshot"),
    "--platform=" + str(sdk / "lib/_internal/vm_platform_product.dill"),
    "--packages=" + args.packages, "--aot", "--target-os=" + target,
    "-Ddart.vm.product=true", "--no-embed-sources",
    "--output=" + str(kernel), args.entry,
], check=True)
subprocess.run([
    generator,
    "--deterministic", "--target_unknown_cpu", "--strip",
    "--snapshot_kind=app-aot-elf", "--elf=" + args.output, str(kernel),
], check=True)
