#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-35, AC-35.02.
import base64
import unittest

from check_appcast import audit


MANIFEST = {
    "tag": "v9.8.7", "version": "9.8.7", "build": "42", "deploymentTarget": "14.0",
    "updateArchive": "Example-9.8.7-macos-arm64.zip",
    "updateFeed": "https://example.invalid/owner/app/releases/latest/download/appcast.xml",
}
NOTES = "# Example 9.8.7\n\nWhat changed.\n"
SIGNATURE = base64.b64encode(bytes(64)).decode()


def feed(version="9.8.7", build="42", minimum="14.0", length="1000", signature=SIGNATURE,
         address="https://example.invalid/owner/app/releases/download/v9.8.7/Example-9.8.7-macos-arm64.zip",
         notes='<description sparkle:format="markdown"><![CDATA[' + NOTES + "]]></description>", items=1):
    item = f"""<item><title>{version}</title>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
{notes}
<enclosure url="{address}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item>"""
    return ('<?xml version="1.0" standalone="yes"?>'
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>'
            + item * items + "</channel></rss>")


class AppcastTests(unittest.TestCase):
    def issues(self, **changed):
        return audit(feed(**changed), MANIFEST, 1000, NOTES)

    def test_a_feed_that_describes_the_packaged_release_is_accepted(self):
        self.assertEqual(self.issues(), [])

    def test_the_version_build_and_minimum_system_are_the_release_s(self):
        self.assertEqual(self.issues(version="9.8.6"), ["version 9.8.6 is not the release's 9.8.7"])
        # The build number decides whether installed copies are offered the update at all.
        self.assertEqual(self.issues(build="41"), ["build 41 is not the release's 42"])
        self.assertEqual(self.issues(minimum="13.0"), ["minimum system 13.0 is not the release's 14.0"])

    def test_the_archive_is_named_by_its_tagged_address_and_exact_length(self):
        latest = "https://example.invalid/owner/app/releases/latest/download/Example-9.8.7-macos-arm64.zip"
        self.assertEqual(self.issues(address=latest), [
            "the archive address is not https://example.invalid/owner/app/releases/download/v9.8.7/"
            "Example-9.8.7-macos-arm64.zip"])
        self.assertEqual(self.issues(length="999"), ["the archive length 999 is not the packaged 1000 bytes"])

    def test_the_archive_carries_a_whole_signature(self):
        self.assertEqual(self.issues(signature=""), ["the archive has no signature of 64 bytes"])
        self.assertEqual(self.issues(signature=base64.b64encode(bytes(12)).decode()),
                         ["the archive has no signature of 64 bytes"])

    def test_the_notes_are_embedded_and_are_the_release_s_own(self):
        link = ("<sparkle:releaseNotesLink>https://example.invalid/owner/app/releases/latest/download/"
                "Example-9.8.7-macos-arm64.md</sparkle:releaseNotesLink>")
        # A link names a file the release does not carry, so the reader of the update would see no notes.
        self.assertEqual(self.issues(notes=link), ["the release notes are linked instead of embedded"])
        other = '<description sparkle:format="markdown"><![CDATA[# Another release]]></description>'
        self.assertEqual(self.issues(notes=other), ["the embedded notes are not the release's notes"])

    def test_one_feed_announces_one_release(self):
        self.assertEqual(self.issues(items=2), ["the feed lists 2 updates instead of one"])
        self.assertEqual(audit("not a feed", MANIFEST, 1000, NOTES), ["the feed is not readable"])

    def test_a_release_with_another_feed_address_is_not_guessed_at(self):
        manifest = dict(MANIFEST, updateFeed="https://example.invalid/feed.xml")
        self.assertEqual(audit(feed(), manifest, 1000, NOTES),
                         ["the release's feed address does not end in /releases/latest/download/appcast.xml"])


if __name__ == "__main__":
    unittest.main()
