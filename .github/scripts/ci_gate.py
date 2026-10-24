#!/usr/bin/env python3
"""Preserve the required check: only confirmed docs PRs may skip heavy jobs."""

import json
import os
import sys

EXPENSIVE = {"tests", "wasm-runtime", "consumers", "native", "publication",
             "platform-package", "platform-package-consumers"}


def validate(results, event):
    expected = EXPENSIVE | {"scope", "static"}
    if not isinstance(results, dict) or set(results) != expected:
        raise ValueError("Missing or unexpected validation jobs")
    for name in ("scope", "static"):
        if results[name].get("result") != "success":
            raise ValueError(f"{name} did not succeed")
    scope = results["scope"].get("outputs", {}).get("scope")
    if scope not in ("docs", "full") or (scope == "docs" and event != "pull_request"):
        raise ValueError("Missing or invalid CI scope")
    wanted = "skipped" if scope == "docs" else "success"
    bad = {name: results[name].get("result") for name in EXPENSIVE
           if results[name].get("result") != wanted}
    if bad:
        raise ValueError(f"Expected {wanted} validation jobs: {bad}")


if __name__ == "__main__":
    try:
        validate(json.loads(os.environ["RESULTS"]), os.environ["GITHUB_EVENT_NAME"])
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        sys.exit(str(error))
    print("All required validation jobs have the expected results.")
