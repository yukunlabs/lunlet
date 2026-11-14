#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-34, AC-34.02.
"""Keeps private data out of the repository.

Fixtures, comments and documents are written with synthetic values. A value copied from a real machine or account
names its owner for good once it is pushed, so this check refuses, in every tracked text file:

- a home folder that is not a placeholder (`/Users/<account>`, `/Users/synthetic`, `~/…` are fine);
- a mail address outside the reserved example domains and GitHub's no-reply addresses;
- anything shaped like a private key or an access token.

A fixture that must look like a secret says `synthetic` on its line. Upstream license texts keep their authors'
addresses. A problem is reported by file and line; the value itself is never printed.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXEMPT = "synthetic"
# Upstream texts, and the one file that has to spell out what this check refuses.
SKIPPED = ("Resources/third-party/", "scripts/test_private_data.py")
HOME = re.compile(r"/(?:Users|home)/([^/\s\"'`)]+)")
PLACEHOLDER_HOMES = {"someone", "example", "Shared", "runner"}
MAIL = re.compile(r"[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})")
RESERVED_MAIL = {"example.com", "example.org", "example.net", "users.noreply.github.com"}
SECRET = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}"
    r"|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{20,}"
    r"|\bsk-[A-Za-z0-9_-]{20,}"
    r"|\b\d{8,10}:[A-Za-z0-9_-]{35}\b")


def problems(text):
    """The private-looking values in one file, as (line number, kind) pairs."""
    found = []
    for number, line in enumerate(text.split("\n"), 1):
        if EXEMPT in line:
            continue
        for match in HOME.finditer(line):
            name = match.group(1)
            if name[0] not in "<$%{" and name not in PLACEHOLDER_HOMES:
                found.append((number, "a home folder"))
        for match in MAIL.finditer(line):
            # The part before the @ of an address in a URL, and the user of a remote shell, are not mail.
            start = line.rfind(" ", 0, match.start()) + 1
            if "://" in line[start:match.start()] or match.group(0) == "git@github.com":
                continue
            domain = match.group(1).lower()
            if domain not in RESERVED_MAIL and not domain.endswith(".invalid"):
                found.append((number, "a mail address"))
        if SECRET.search(line):
            found.append((number, "a key or token"))
    return found


def main(root=ROOT):
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    failed = False
    for name in sorted(value.decode() for value in listed.split(b"\0") if value):
        if name.startswith(SKIPPED):
            continue
        try:
            text = (root / name).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue  # Pictures, the film and other binary files.
        for number, kind in problems(text):
            print(f"::error file={name},line={number}::{kind} that is not a placeholder; use a synthetic value")
            failed = True
    if failed:
        return 1
    print("The tracked files hold no private-looking values.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
