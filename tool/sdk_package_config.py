"""Index compiler packages from the paired Dart SDK source checkout."""

import argparse
import json
import os
from pathlib import Path
import re


def package(root):
    pubspec = root / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    name = re.search(r"^name:\s*([a-z_][a-z0-9_]*)\s*(?:#.*)?$", text, re.MULTILINE)
    environment = re.search(
        r"^environment:[ \t]*(?:#.*)?\n((?:[ \t][^\n]*\n|\n)*)",
        text + "\n",
        re.MULTILINE,
    )
    language = None if environment is None else re.search(
        r"^[ \t]+sdk:[ \t]*['\"]?(?:\^|>=)[ \t]*(\d+)\.(\d+)",
        environment.group(1),
        re.MULTILINE,
    )
    if name is None or language is None:
        raise ValueError(f"Unsupported package name or SDK constraint in {pubspec}")
    return {
        "name": name.group(1),
        "rootUri": root.as_uri() + "/",
        "packageUri": "lib/",
        "languageVersion": f"{language.group(1)}.{language.group(2)}",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sdk = args.sdk.resolve(strict=True)
    packages = {}
    for base in (sdk / "pkg", sdk / "third_party/pkg"):
        if not base.is_dir():
            parser.error(f"Missing SDK package directory: {base}")
        for directory, children, files in os.walk(base):
            children[:] = sorted(
                child for child in children
                if not child.startswith(".") and child not in {
                    "test", "tests", "example", "examples",
                    "benchmark", "benchmarks", "fixtures",
                }
            )
            root = Path(directory)
            if "pubspec.yaml" not in files or not (root / "lib").is_dir():
                continue
            children.clear()
            entry = package(root)
            name = entry["name"]
            if name in packages:
                parser.error(f"Duplicate SDK package {name}: {root}")
            packages[name] = entry
    for name in ("front_end", "kernel", "vm", "package_config"):
        if name not in packages:
            parser.error(f"Missing SDK compiler package: {name}")
    content = json.dumps({
        "configVersion": 2,
        "packages": [packages[name] for name in sorted(packages)],
    }, indent=2) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_text(encoding="utf-8") != content:
        args.output.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
