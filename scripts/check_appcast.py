#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-35, AC-35.02.
"""Checks a generated update feed against the packaged release it announces.

Installed copies act on what the feed says: the build number decides whether the update is offered, the address and
length name the archive, the signature lets it install, and the embedded notes are what the reader sees. The feed is
written once per release by Sparkle's generate_appcast, outside the packager, so this check compares it with the
release directory before it is published. It does not verify the signature itself, which needs the private key's
other half and Sparkle's own tools.

usage: check_appcast.py <appcast.xml> <release directory> [<release notes>]
"""
import base64
import binascii
import json
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
FEED_SUFFIX = "/releases/latest/download/appcast.xml"


def audit(feed, manifest, archive_size, notes):
    try:
        items = ElementTree.fromstring(feed).findall("./channel/item")
    except ElementTree.ParseError:
        return ["the feed is not readable"]
    if len(items) != 1:
        return [f"the feed lists {len(items)} updates instead of one"]
    if not manifest["updateFeed"].endswith(FEED_SUFFIX):
        return ["the release's feed address does not end in " + FEED_SUFFIX]
    item, issues = items[0], []
    enclosure = item.find("enclosure")
    enclosure = enclosure if enclosure is not None else ElementTree.Element("enclosure")

    for name, tag, expected in (("version", "shortVersionString", manifest["version"]),
                                ("build", "version", manifest["build"]),
                                ("minimum system", "minimumSystemVersion", manifest["deploymentTarget"])):
        found = item.findtext(SPARKLE + tag, "")
        if found != expected:
            issues.append(f"{name} {found} is not the release's {expected}")

    address = (manifest["updateFeed"][:-len(FEED_SUFFIX)] + "/releases/download/" + manifest["tag"] + "/"
               + manifest["updateArchive"])
    if enclosure.get("url") != address:
        issues.append("the archive address is not " + address)
    if enclosure.get("length") != str(archive_size):
        issues.append(f"the archive length {enclosure.get('length')} is not the packaged {archive_size} bytes")
    try:
        signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
    except (binascii.Error, ValueError):
        signature = b""
    if len(signature) != 64:
        issues.append("the archive has no signature of 64 bytes")

    description = item.find("description")
    if item.find(SPARKLE + "releaseNotesLink") is not None or description is None:
        issues.append("the release notes are linked instead of embedded")
    elif description.get(SPARKLE + "format") != "markdown" or (description.text or "").strip() != notes.strip():
        issues.append("the embedded notes are not the release's notes")
    return issues


def main(arguments):
    if len(arguments) not in (2, 3):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    release = Path(arguments[1])
    try:
        manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
        notes_path = Path(arguments[2]) if len(arguments) == 3 else (
            Path(__file__).resolve().parent.parent / "docs/release-notes" / (manifest["tag"] + ".md"))
        issues = audit(Path(arguments[0]).read_text(encoding="utf-8"), manifest,
                       (release / manifest["updateArchive"]).stat().st_size, notes_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        print(f"Cannot read the feed, the release directory or its notes: {type(error).__name__}", file=sys.stderr)
        return 1
    for issue in issues:
        print(issue, file=sys.stderr)
    if issues:
        return 1
    print(f"The update feed describes {manifest['tag']}, build {manifest['build']}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
