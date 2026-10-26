#!/usr/bin/env python3
"""Remove registration objects replaced by a reduced runtime profile."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ar", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=["core", "regexp"], required=True)
    args = parser.parse_args()
    members = subprocess.check_output([args.ar, "t", str(args.input)],
                                      text=True).splitlines()
    names = ["io_natives", "dart_io_api_impl", "io_service", "io_service_no_ssl"]
    if args.profile == "core":
        names.append("bootstrap_natives")
    removed = []
    for name in names:
        matches = [member for member in members
                   if re.search(r"\." + name + r"\.(?:o|obj)$", member)]
        if len(matches) != 1:
            raise ValueError(f"Expected one SDK {name} object, found {matches}")
        removed.extend(matches)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.input, args.output)
    subprocess.run([args.ar, "ds", str(args.output), *removed], check=True)


if __name__ == "__main__":
    main()
