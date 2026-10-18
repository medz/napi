#!/usr/bin/env python3
"""Fail-closed classification of the complete pull-request change range.

GitHub's base SHA is the target branch tip, not necessarily the fork point.
Compare the unique merge base of that SHA and the PR head SHA to the head,
not HEAD^ (only the last commit) or base..head (includes target-only changes).
The checkout may be GitHub's synthetic merge commit; it is not the PR head.
Missing commits, shallow history, ambiguous merge bases and git errors use full CI.
"""

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def is_doc(path):
    parts = PurePosixPath(path).parts
    return (len(parts) >= 2 and parts[0] == "doc" and
            all(part not in (".", "..") for part in parts) and
            path.endswith(".md"))


def classify(repo, event, base=None, head=None):
    if event != "pull_request":
        return "full"
    try:
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                   for sha in (base, head)):
            return "full"
        if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
            return "full"
        for sha in (base, head):
            if git(repo, "cat-file", "-t", sha).strip() != b"commit":
                return "full"
        merge_bases = git(repo, "merge-base", "--all", base, head).splitlines()
        if len(merge_bases) != 1:
            return "full"
        # Disable rename detection: both sides must independently be ordinary
        # doc Markdown. A move into doc/ from any other path therefore stays full.
        raw = git(repo, "diff", "--raw", "-z", "--no-renames", "--no-ext-diff",
                  merge_bases[0].decode("ascii"), head, "--")
        fields = raw.split(b"\0")
        if not raw or fields.pop() != b"" or len(fields) % 2:
            return "full"
        for index in range(0, len(fields), 2):
            header = fields[index].decode("ascii").split()
            path = fields[index + 1].decode("utf-8")
            if len(header) != 5 or not is_doc(path):
                return "full"
            old_mode, new_mode, _, _, status = header
            modes = (old_mode.removeprefix(":"), new_mode)
            allowed = {"A": ("000000", "100644"),
                       "D": ("100644", "000000"),
                       "M": ("100644", "100644")}
            if not old_mode.startswith(":") or modes != allowed.get(status):
                return "full"
        return "docs"
    except (OSError, subprocess.SubprocessError, UnicodeError, ValueError):
        return "full"


def main():
    scope = "full"
    try:
        event = os.environ.get("GITHUB_EVENT_NAME", "")
        if event == "pull_request":
            payload = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
            pr = payload["pull_request"]
            scope = classify(".", event, pr["base"]["sha"], pr["head"]["sha"])
    except (OSError, KeyError, TypeError, ValueError):
        pass
    print(f"CI scope: {scope}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"scope={scope}\n")


if __name__ == "__main__":
    main()
