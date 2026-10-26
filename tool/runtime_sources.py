#!/usr/bin/env python3
"""Generate reduced native registration tables for the prebuilt SDK runtimes."""

import argparse
from pathlib import Path
import re


def without_entries(source, macro, prefixes):
    pattern = rf"#define {macro}\(V\).*?(?=\n\n)"
    match = re.search(pattern, source, flags=re.DOTALL)
    if match is None:
        raise ValueError(f"Missing SDK native list: {macro}")
    lines = match.group().splitlines(keepends=True)
    kept = [line for line in lines
            if not re.search(r"\bV\((?:" + "|".join(prefixes) + r")", line)]
    if len(lines) == len(kept):
        raise ValueError(f"No matching entries in SDK native list: {macro}")
    return source[:match.start()] + "".join(kept) + source[match.end():]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    header = (args.sdk / "runtime/vm/bootstrap_natives.h").read_text()
    reduced = without_entries(header, "BOOTSTRAP_NATIVE_LIST", ["RegExp"])
    macro = re.search(r"#define BOOTSTRAP_NATIVE_LIST\(V\).*?(?=\n\n)",
                      reduced, flags=re.DOTALL).group()
    bootstrap = (args.sdk / "runtime/vm/bootstrap_natives.cc").read_text()
    include = '#include "vm/bootstrap_natives.h"'
    if bootstrap.count(include) != 1:
        raise ValueError("Unexpected SDK bootstrap native source")
    bootstrap = bootstrap.replace(
        include, include + "\n#undef BOOTSTRAP_NATIVE_LIST\n" + macro + "\n")
    (args.output / "bootstrap_no_regexp.cc").write_text(bootstrap)

    io = (args.sdk / "runtime/bin/io_natives.cc").read_text()
    io = without_entries(io, "IO_NATIVE_LIST",
                         ["SecureSocket", "SecurityContext", "X509"])
    (args.output / "io_no_tls.cc").write_text(io)


if __name__ == "__main__":
    main()
