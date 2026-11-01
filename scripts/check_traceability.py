#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.04; US-11, AC-11.05; US-29, AC-29.02.
# Supporting check: keep continuation authorization and recovery code tied to
# confirmed criteria. Reference validity does not prove behavioral compliance.
from pathlib import Path
import re
import subprocess
import sys


CODE_SUFFIXES = {".swift", ".py", ".sh", ".yml", ".yaml", ".plist", ".proto", ".html", ".css", ".js"}
TEXT_SUFFIXES = CODE_SUFFIXES | {".md", ".json", ".toml", ".txt"}
REFERENCE = re.compile(r"\b(?:US-\d+|AC-\d+\.\d+)\b")
CHINESE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")


def audit(root, files):
    issues = []
    try:
        specification = (root / "docs/requirements.md").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ["Cannot read docs/requirements.md"]

    stories = {}
    criteria = {}
    sections = re.split(r"(?m)^### (US-\d+):[^\n]*\n", specification)
    for index in range(1, len(sections), 2):
        story, body = sections[index:index + 2]
        status = re.search(r"(?m)^Status: (\w+)\.", body)
        if story in stories:
            issues.append("Duplicate story ID: " + story)
        stories[story] = status.group(1) if status else "Unknown"
        for criterion in re.findall(r"\*\*(AC-\d+\.\d+)\*\*", body):
            if criterion in criteria:
                issues.append("Duplicate criterion ID: " + criterion)
            criteria[criterion] = story
            if "US-" + criterion[3:].split(".")[0] != story:
                issues.append("Criterion has an inconsistent parent: " + criterion)

    # Each story has exactly one primary Epic in the summary table.
    epics = {}
    for row in re.findall(r"(?m)^\| (EPIC-\d+) \|[^\n]*\| ((?:US-\d+(?:, )?)+) \|$", specification):
        for story in re.findall(r"US-\d+", row[1]):
            epics.setdefault(story, []).append(row[0])
    for story in sorted(stories):
        if len(epics.get(story, [])) != 1:
            issues.append("Story needs exactly one primary Epic: " + story)
    for story in sorted(set(epics) - set(stories)):
        issues.append("Epic lists an unknown story: " + story)

    for relative in files:
        if relative.suffix not in TEXT_SUFFIXES and relative.name != ".gitignore":
            continue
        path = root / relative
        if path.is_symlink():
            issues.append(str(relative) + ": symlink requires manual review")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            issues.append(str(relative) + ": cannot read UTF-8 source")
            continue
        if CHINESE.search(content):
            issues.append(str(relative) + ": repository language rule violated")
        if relative.suffix not in CODE_SUFFIXES:
            continue

        # Sixteen lines cover a generated file whose generator banner precedes the declaration's own header.
        header = "\n".join(content.splitlines()[:16])
        # Project-owned source states its license and holder (AC-29.02); generated files keep their own header.
        if "Generated" not in relative.parts and not (
                "SPDX-FileCopyrightText:" in header and "SPDX-License-Identifier: 0BSD" in header):
            issues.append(str(relative) + ": missing SPDX license header")
        references = set(REFERENCE.findall(header))
        story_refs = {value for value in references if value.startswith("US-")}
        criterion_refs = references - story_refs
        if "Refs:" not in header or not story_refs or not criterion_refs:
            issues.append(str(relative) + ": missing story and criterion references")
        for story in sorted(story_refs):
            if stories.get(story) != "Confirmed":
                issues.append(str(relative) + ": unknown or unconfirmed story " + story)
        for criterion in sorted(criterion_refs):
            parent = criteria.get(criterion)
            if parent not in story_refs or stories.get(parent) != "Confirmed":
                issues.append(str(relative) + ": unknown, unconfirmed, or mismatched criterion " + criterion)
    return issues


def main():
    root = Path(__file__).resolve().parent.parent
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, capture_output=True,
    )
    files = sorted({Path(value.decode()) for value in result.stdout.split(b"\0") if value})
    issues = audit(root, files)
    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1
    print("Traceability and source language checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
