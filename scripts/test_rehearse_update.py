#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-35, AC-35.02.
import os
import tempfile
import unittest
from pathlib import Path

from rehearse_update import differences, local_feed, refusal

FEED = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
<sparkle:version>42</sparkle:version><sparkle:shortVersionString>9.8.7</sparkle:shortVersionString>
<description sparkle:format="markdown"><![CDATA[# Example 9.8.7]]></description>
<enclosure url="https://example.invalid/owner/app/releases/download/v9.8.7/Example-9.8.7-macos-arm64.zip" length="1000" type="application/octet-stream" sparkle:edSignature="c2lnbmF0dXJl"/>
</item></channel></rss>"""
MANIFEST = {"version": "9.8.7", "build": "42", "updateArchive": "Example-9.8.7-macos-arm64.zip"}


class RehearsalTests(unittest.TestCase):
    def test_the_local_feed_changes_only_where_the_archive_comes_from(self):
        local = local_feed(FEED, "http://127.0.0.1:8123", MANIFEST["updateArchive"])
        self.assertIn('url="http://127.0.0.1:8123/Example-9.8.7-macos-arm64.zip"', local)
        # The version, the length, the signature and the notes are the published ones.
        self.assertEqual(local.replace("http://127.0.0.1:8123/", "https://example.invalid/owner/app/releases/download/v9.8.7/"), FEED)
        with self.assertRaises(ValueError):
            local_feed(FEED.replace("Example-9.8.7", "Other-1.0.0"), "http://127.0.0.1:8123", MANIFEST["updateArchive"])

    def test_only_an_older_release_build_can_rehearse(self):
        release = {"build": "41", "feed": "https://example.invalid/appcast.xml", "preview": False}
        self.assertIsNone(refusal(release, MANIFEST))
        # A copy that is not older would be offered nothing.
        self.assertEqual(refusal(dict(release, build="42"), MANIFEST),
                         "the installed copy is build 42; the candidate is build 42 and would not be offered to it")
        # A preview, or a build without a feed, has no updater.
        self.assertEqual(refusal(dict(release, preview=True), MANIFEST), "the installed copy is a preview and has no updater")
        self.assertEqual(refusal(dict(release, feed=None), MANIFEST), "the installed copy is a preview and has no updater")

    def test_two_bundles_are_compared_file_by_file(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-rehearsal-test-") as temporary:
            root = Path(temporary)
            for name in ["one", "two"]:
                (root / name / "Contents/MacOS").mkdir(parents=True)
                (root / name / "Contents/MacOS/app").write_bytes(b"executable")
                (root / name / "Contents/Info.plist").write_text("info")
                os.symlink("MacOS/app", root / name / "Contents/current")
            self.assertEqual(differences(root / "one", root / "two"), [])
            (root / "two/Contents/Info.plist").write_text("changed")
            (root / "two/Contents/extra").write_text("extra")
            (root / "one/Contents/only-here").write_text("x")
            os.remove(root / "two/Contents/current")
            os.symlink("MacOS/other", root / "two/Contents/current")
            self.assertEqual(differences(root / "one", root / "two"),
                             ["Contents/Info.plist", "Contents/current", "Contents/extra", "Contents/only-here"])


if __name__ == "__main__":
    unittest.main()
