#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-26, AC-26.01.
"""Keeps test settings out of the user's Library.

A settings domain a test opens by name gets a file in ~/Library/Preferences, and removing the domain leaves that
file there, empty: one more for every test on every run. The shared settings of the test process are a real file
too. Tests therefore take their settings from `ScratchSettings.make`, which names the domain by a path in a
temporary directory. This check refuses, anywhere else under Tests, a domain opened with `UserDefaults(suiteName:)`
and any use of the shared `UserDefaults.standard`.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = "ScratchSettings.swift"
OWN = re.compile(r"UserDefaults\(suiteName:\s*[^)]")
SHARED = re.compile(r"UserDefaults\.standard\b|\bdefaults:\s*\.standard\b")


def problems(text):
    """The lines of one test file that put settings in the user's Library, as (line number, message) pairs."""
    found = []
    for number, line in enumerate(text.split("\n"), 1):
        code = line.split("//", 1)[0]
        if OWN.search(code):
            found.append((number, "opens a settings domain of its own; use ScratchSettings.make"))
        if SHARED.search(code):
            found.append((number, "uses the shared settings of the test process; use ScratchSettings.make"))
    return found


def main(root=ROOT):
    failed = False
    for path in sorted((root / "Tests").rglob("*.swift")):
        if path.name == HELPER:
            continue
        for number, message in problems(path.read_text(encoding="utf-8")):
            print(f"::error file={path.relative_to(root)},line={number}::{message}")
            failed = True
    if failed:
        return 1
    print("Test settings stay out of the user's Library.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
