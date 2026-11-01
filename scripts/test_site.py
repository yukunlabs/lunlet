#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.01, AC-28.02, AC-28.03, AC-28.04; US-30, AC-30.01, AC-30.02, AC-30.03.
import tempfile
import unittest
from pathlib import Path

from build_site import load_config, build


class ProductSiteTests(unittest.TestCase):
    def config(self, source):
        with tempfile.TemporaryDirectory(prefix="lunlet-site-test-") as temporary:
            path = Path(temporary) / "config.json"
            path.write_text(source)
            return load_config(path)

    def test_absent_release_and_support_destinations_stay_absent(self):
        self.assertEqual(self.config('{"schemaVersion":1}'), {})
        self.assertEqual(self.config('{"schemaVersion":1,"supportURL":null}'), {})

    def test_real_format_destinations_are_retained_without_rewriting(self):
        source = '{"schemaVersion":1,"repositoryURL":"https://github.com/example/lunlet","releaseURL":"https://github.com/example/lunlet/releases/tag/v0.1.0","supportURL":"https://example.com/support"}'
        config = self.config(source)
        self.assertEqual(config['releaseURL'], 'https://github.com/example/lunlet/releases/tag/v0.1.0')
        self.assertEqual(config['supportURL'], 'https://example.com/support')

    def test_configuration_rejects_unsafe_unverified_or_unknown_destinations(self):
        invalid = [
            '{"schemaVersion":99}', '{"schemaVersion":1,"unknown":true}',
            '{"schemaVersion":1,"supportURL":"javascript:alert(1)"}',
            '{"schemaVersion":1,"supportURL":"https://user:password@example.com/pay"}',
            '{"schemaVersion":1,"supportURL":"/placeholder"}',
            '{"schemaVersion":1,"releaseURL":"https://example.com/download"}',
            '{"schemaVersion":1,"releaseURL":"https://github.com/owner/repo"}',
            '{"schemaVersion":1,"repositoryURL":"https://github.com"}',
        ]
        for source in invalid:
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    self.config(source)

    def test_source_and_release_destinations_must_identify_the_same_repository(self):
        for release in ("https://github.com/other/lunlet/releases/tag/v0.1.0",
                        "https://github.com/example/other/releases/latest"):
            with self.subTest(release=release), self.assertRaises(ValueError):
                self.config('{"schemaVersion":1,"repositoryURL":"https://github.com/example/lunlet","releaseURL":"' + release + '"}')

    def test_github_destinations_require_their_actual_repository_or_release_path(self):
        invalid = [
            ("releaseURL", "https://github.com/example/releases"),
            ("releaseURL", "https://github.com/example/releases/"),
            ("repositoryURL", "https://github.com/example/lunlet/releases"),
            ("repositoryURL", "https://github.com/example/lunlet/releases/tag/v0.1.0"),
        ]
        for key in ("repositoryURL", "releaseURL"):
            suffix = "/releases/tag/v0.1.0" if key == "releaseURL" else ""
            for owner, repository in ((".", "lunlet"), ("..", "lunlet"), ("...", "lunlet"),
                                      ("example", "."), ("example", ".."), ("example", "...")):
                invalid.append((key, "https://github.com/" + owner + "/" + repository + suffix))
        for key, destination in invalid:
            with self.subTest(key=key, destination=destination), self.assertRaises(ValueError):
                self.config('{"schemaVersion":1,"' + key + '":"' + destination + '"}')

    def test_real_release_paths_accept_a_repository_named_releases(self):
        for suffix in ("/releases", "/releases/", "/releases/latest", "/releases/tag/v0.1.0"):
            release = "https://github.com/example/releases" + suffix
            config = self.config('{"schemaVersion":1,"repositoryURL":"https://github.com/example/releases","releaseURL":"' + release + '"}')
            self.assertEqual(config["releaseURL"], release)

    def test_optional_destinations_and_repository_case_remain_supported(self):
        release = "https://github.com/example/lunlet/releases/tag/v0.1.0"
        self.assertEqual(self.config('{"schemaVersion":1,"releaseURL":"' + release + '"}'), {"releaseURL": release})
        source = "https://github.com/Example/Lunlet/"
        config = self.config('{"schemaVersion":1,"repositoryURL":"' + source + '","releaseURL":"' + release + '"}')
        self.assertEqual(config, {"repositoryURL": source, "releaseURL": release})

    def test_build_is_self_contained_and_does_not_publish_placeholder_links(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-site-test-") as temporary:
            output = Path(temporary) / "site"
            config = Path(temporary) / "config.json"
            config.write_text('{"schemaVersion":1}')
            build(output, config_path=config)
            self.assertTrue((output / "index.html").is_file())
            self.assertTrue((output / "assets/lunlet-app-icon.png").is_file())
            self.assertTrue((output / "video/lunlet-walkthrough.mp4").is_file())
            self.assertTrue((output / "video/lunlet-poster.jpg").is_file())
            self.assertTrue((output / "video/lunlet-captions.vtt").is_file())
            page = (output / "index.html").read_text()
            self.assertIn('<video class="product-film" controls playsinline preload="none"', page)
            self.assertIn('kind="captions"', page)
            self.assertNotIn('<video autoplay', page)
            self.assertEqual((output / "site-config.js").read_text(), "window.LUNLET_SITE_CONFIG = {};\n")
            artwork = (output / "artwork.js").read_text()
            self.assertIn('"leftInk"', artwork)
            self.assertIn('"palette"', artwork)
            self.assertNotIn('localhost', (output / "index.html").read_text())
            with self.assertRaises(FileExistsError):
                build(output)


if __name__ == "__main__":
    unittest.main()
