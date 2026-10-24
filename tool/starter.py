"""Package the example as a standalone starter for the current napi release."""

import argparse
from pathlib import Path
import re
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    manifest = (root / "pubspec.yaml").read_text()
    version = re.search(r"^version: ([0-9]+\.[0-9]+\.[0-9]+(?:-[\w.-]+)?)$", manifest, re.M)
    if version is None:
        raise ValueError("pubspec.yaml must declare a package version")
    files = (
        ".gitignore", "README.md", "pubspec.yaml", "lib/counter.dart",
        "tool/build.dart", "example.mjs",
    )
    contents = {name: (root / "example" / name).read_text() for name in files}
    contents["pubspec.yaml"], count = re.subn(
        r"(?m)^  napi:\n    path: \.\.$",
        f"  napi: ^{version.group(1)}", contents["pubspec.yaml"],
    )
    if count != 1:
        raise ValueError("example must use the repository napi dependency")
    contents["LICENSE"] = (root / "LICENSE").read_text()
    # Exclusive creation avoids replacing a previously prepared release asset.
    with zipfile.ZipFile(args.output, "x", zipfile.ZIP_DEFLATED) as archive:
        for name, content in contents.items():
            archive.writestr(f"napi-starter/{name}", content)


if __name__ == "__main__":
    main()
