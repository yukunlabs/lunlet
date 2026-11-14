#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.02.
"""Tells the validation workflow which of its slow areas a change can affect.

The Swift modules and the release tooling run on macOS and take minutes. Prose, the product page and the Python
checks cannot change their result, so a change made only of those skips them. A path skips an area only when a rule
here says so; anything unknown, the workflow and these rules themselves run everything.

usage: changed_areas.py <base revision> <head revision>
It prints `swift=true|false` and `release=true|false`, the form a workflow step output takes.
"""
import subprocess
import sys

# What the release tooling's tests read besides the scripts and resources they package.
RELEASE_READS = {"docs/releases.md", "NOTICE.md", "scripts/test_release.py", "scripts/check_appcast.py",
                 "scripts/test_appcast.py", "scripts/rehearse_update.py", "scripts/test_rehearse_update.py"}


def unaffecting(path):
    """Prose, the product page with its rendered media, and the Python checks, which have their own areas."""
    prose = (path.startswith(("docs/", "website/", ".github/ISSUE_TEMPLATE/"))
             or path == ".github/pull_request_template.md" or ("/" not in path and path.endswith(".md")))
    python_check = path.startswith("scripts/") and path.endswith(".py") and path != "scripts/changed_areas.py"
    return prose or python_check


def areas(paths):
    """Which slow areas `paths` can affect; `None` means the change is unknown, and everything runs."""
    if paths is None:
        return {"swift": True, "release": True}
    return {"swift": any(not unaffecting(path) for path in paths),
            "release": any(path in RELEASE_READS or not unaffecting(path) for path in paths)}


def changed(base, head):
    if not base or set(base) == {"0"}:
        return None
    result = subprocess.run(["git", "diff", "--name-only", "-z", base, head], capture_output=True)
    if result.returncode != 0:
        return None
    return [value.decode() for value in result.stdout.split(b"\0") if value]


def main(arguments):
    paths = changed(*arguments) if len(arguments) == 2 else None
    for area, needed in areas(paths).items():
        print(f"{area}={'true' if needed else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
