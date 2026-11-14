#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.02.
"""Keeps test waits independent of the machine's speed.

A test that waits for something waits on the condition, and its budget only bounds a hang. A hosted runner can be
many times slower than a developer's Mac, and the desktop tests queue behind one another on the main thread, so a
budget of a few seconds fails there for no fault of the code. This check refuses, anywhere under Tests:

- a deadline of less than 30 seconds (`ContinuousClock.now + .seconds(N)`, `wait(timeout: .now() + N)`);
- a counted polling loop (one that sleeps and leaves early) whose sleeps add up to less than 20 seconds.

A wait that is short on purpose, such as a window in which nothing must happen, says so on its line with the words
`short on purpose`.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEADLINE = re.compile(r"ContinuousClock\.now \+ \.seconds\((\d+)\)|wait\(timeout: \.now\(\) \+ (\d+(?:\.\d+)?)\)")
LOOP = re.compile(r"for _ in 0\.\.<([\d_]+) \{")
SLEEP = re.compile(r"Task\.sleep\(for: \.milliseconds\((\d+)\)\)|usleep\(([\d_]+)\)")
MINIMUM_DEADLINE = 30
MINIMUM_LOOP_MILLISECONDS = 20_000
EXEMPT = "short on purpose"


def problems(text):
    """The waits in one file that a slow machine would fail, as (line number, message) pairs."""
    found = []
    lines = text.split("\n")
    for number, line in enumerate(lines, 1):
        if EXEMPT in line:
            continue
        for match in DEADLINE.finditer(line):
            seconds = float(match.group(1) or match.group(2))
            if seconds < MINIMUM_DEADLINE:
                found.append((number, f"a deadline of {seconds:g} s; allow at least {MINIMUM_DEADLINE} s"))
        loop = LOOP.search(line)
        if loop:
            # A wait is a loop that sleeps and leaves early; one that only repeats or samples is not.
            count = int(loop.group(1).replace("_", ""))
            indent = len(line) - len(line.lstrip())
            body = [line]
            # A loop written on one line is its own body.
            for later in ([] if line.rstrip().endswith("}") else lines[number:]):
                if later.strip() == "}" and len(later) - len(later.lstrip()) == indent:
                    break
                body.append(later)
            sleep = next((match for match in map(SLEEP.search, body) if match), None)
            leaves = any(re.search(r"\b(break|return)\b", later) for later in body)
            if sleep and leaves:
                each = float(sleep.group(1)) if sleep.group(1) else int(sleep.group(2).replace("_", "")) / 1000
                if count * each < MINIMUM_LOOP_MILLISECONDS:
                    found.append((number, f"a polling loop of {count * each / 1000:g} s in all; allow at least "
                                          f"{MINIMUM_LOOP_MILLISECONDS // 1000} s"))
    return found


def main(root=ROOT):
    failed = False
    for path in sorted((root / "Tests").rglob("*.swift")):
        for number, message in problems(path.read_text(encoding="utf-8")):
            print(f"::error file={path.relative_to(root)},line={number}::{message}")
            failed = True
    if failed:
        return 1
    print("Test waits leave room for a slow machine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
