#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.01, AC-28.02, AC-28.03, AC-28.04; US-30, AC-30.01, AC-30.02, AC-30.03; US-27, AC-27.04.
import re
import tempfile
import unittest
from pathlib import Path

import check_site_assets
from build_site import (build, check_stories, load_config, native_facts, referenced_files, render_page,
                        screenshots, swift_titles)


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
            video = re.search(r'<video [^>]*>', page).group(0)
            self.assertIn('controls', video)
            self.assertIn('preload="none"', video)
            self.assertNotIn('autoplay', video)
            self.assertIn('kind="captions"', page)
            self.assertEqual((output / "site-config.js").read_text(), "window.LUNLET_SITE_CONFIG = {};\n")
            self.assertNotIn('localhost', page)
            # Every picture the page shows is a shipped still of the real interface (AC-28.02), never a hot link.
            referenced = referenced_files(page)
            self.assertTrue({"assets/" + name for name in screenshots(native_facts())} <= referenced)
            for path in referenced:
                self.assertTrue((output / path).is_file(), path)
            self.assertNotIn('src="http', page)
            self.assertNotIn('srcset=', page)
            # One messenger at a time: three tabs, each panel with that channel's three phones (AC-36.01, AC-36.03).
            self.assertEqual(page.count('role="tab"'), 3)
            self.assertEqual(page.count('role="tabpanel"'), 3)
            for channel in ("feishu", "slack", "telegram"):
                panel = re.search(r'<div class="panel" role="tabpanel" id="panel-' + channel + r'".*?</div>\s*</div>', page, re.S).group(0)
                self.assertEqual(panel.count('src="assets/phone-' + channel + '-'), 3)
            with self.assertRaises(FileExistsError):
                build(output)

    def test_release_tag_becomes_the_download_destination(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-site-test-") as temporary:
            path = Path(temporary) / "config.json"
            path.write_text('{"schemaVersion":1,"repositoryURL":"https://github.com/example/lunlet"}')
            self.assertEqual(load_config(path, "v0.1.0")["releaseURL"], "https://github.com/example/lunlet/releases/tag/v0.1.0")
            self.assertNotIn("releaseURL", load_config(path))
            for tag in ("0.1.0", "v0.1.0/../x", "v0.1 0"):
                with self.subTest(tag=tag), self.assertRaises(ValueError):
                    load_config(path, tag)
            path.write_text('{"schemaVersion":1}')
            with self.assertRaises(ValueError):
                load_config(path, "v0.1.0")
            path.write_text('{"schemaVersion":1,"repositoryURL":"https://github.com/example/lunlet",'
                            '"releaseURL":"https://github.com/example/lunlet/releases/tag/v0.0.9"}')
            with self.assertRaises(ValueError):
                load_config(path, "v0.1.0")

    def test_facts_are_read_from_the_sources(self):
        facts = native_facts()
        self.assertEqual([agent for agent, _ in facts["agents"]], ["codex", "claude"])
        self.assertEqual(dict(facts["channels"])["slack"], "Slack")
        self.assertEqual(facts["skins"][0], ("vine", "Vine"))
        self.assertTrue(facts["macOS"].isdigit())
        source = 'enum Fruit: String {\n    case apple, pear\n    var title: String {\n' \
                 '        switch self { case .apple: "Apple"; case .pear: "Pear" }\n    }\n}\n'
        self.assertEqual(swift_titles(source, enum="Fruit"), [("apple", "Apple"), ("pear", "Pear")])
        with self.assertRaises(ValueError):
            swift_titles(source, enum="Vegetable")

    FACTS = {"agents": [("codex", "Codex"), ("claude", "Claude Code")], "channels": [("feishu", "Feishu / Lark"), ("slack", "Slack")],
             "skins": [("vine", "Vine")], "macOS": "14"}
    PAGE = ('<p>{{agents}} on macOS {{macos}}; {{agentsLead}}; {{channels}}; {{skins}}</p><div role="tablist">{{tabs}}</div>'
            '<div class="panel" role="tabpanel" id="panel-feishu"></div><div class="panel" role="tabpanel" id="panel-slack"></div>'
            '<figure data-agent="codex"></figure><figure data-agent="claude"></figure>'
            '<figure data-skin="vine"><figcaption>Vine</figcaption></figure>')

    def test_page_facts_render_and_per_item_blocks_must_cover_the_sources(self):
        page = render_page(self.PAGE, self.FACTS)
        self.assertIn("Codex and Claude Code on macOS 14; Both agents; Feishu / Lark or Slack; Vine", page)
        self.assertIn('<button type="button" role="tab" id="tab-feishu" aria-selected="true" aria-controls="panel-feishu">Feishu / Lark</button>', page)
        self.assertIn('id="tab-slack" aria-selected="false" tabindex="-1"', page)
        three = dict(self.FACTS, agents=self.FACTS["agents"] + [("other", "Other")])
        self.assertIn("All three agents", render_page(self.PAGE + '<figure data-agent="other"></figure>', three))
        for broken, facts in [
            (self.PAGE.replace('<div class="panel" role="tabpanel" id="panel-slack"></div>', ""), self.FACTS),
            (self.PAGE, dict(self.FACTS, channels=self.FACTS["channels"] + [("telegram", "Telegram")])),
            (self.PAGE.replace('<figure data-agent="claude"></figure>', ""), self.FACTS),
            (self.PAGE, dict(self.FACTS, skins=[("vine", "Vine"), ("lantern", "Red lanterns")])),
            (self.PAGE.replace("<figcaption>Vine</figcaption>", "<figcaption>Vines</figcaption>"), self.FACTS),
            (self.PAGE + "{{unknown}}", self.FACTS),
        ]:
            with self.subTest(broken=broken[-60:]), self.assertRaises(ValueError):
                render_page(broken, facts)

    REQUIREMENTS = ("### US-01: Done\n\nStatus: Confirmed.\n\nProduct page: #one.\n\n"
                    "### US-02: Planned\n\nStatus: Proposed.\n\nProduct page: #one.\n\n"
                    "### US-03: Elsewhere\n\nStatus: Confirmed.\n\n")

    def test_sections_present_only_confirmed_stories_and_declared_stories_are_presented(self):
        check_stories('<section id="one" data-stories="US-01 US-03"></section>', self.REQUIREMENTS)
        for page in ['<section id="one" data-stories="US-01 US-02"></section>',   # a proposed story advertised
                     '<section id="one" data-stories="US-03"></section>',         # the declared story missing
                     '<section id="two" data-stories="US-01"></section>',         # the declared section missing
                     '<section id="one" data-stories="US-01"></section><section class="x"></section>',  # untagged section
                     '<section id="one" data-stories="US-01 US-99"></section>']:  # an unknown story
            with self.subTest(page=page), self.assertRaises(ValueError):
                check_stories(page, self.REQUIREMENTS)

    def test_render_manifest_reports_changed_added_removed_and_missing_files(self):
        with tempfile.TemporaryDirectory(prefix="lunlet-site-test-") as temporary:
            root = Path(temporary)
            (root / "src").mkdir(); (root / "out").mkdir()
            (root / "src/a.swift").write_text("a"); (root / "src/b.swift").write_text("b"); (root / "out/x.png").write_bytes(b"x")
            kind = {"name": "film", "manifest": "manifest.json", "inputs": ("src/**/*.swift",), "outputs": ("out/x.png", "out/y.png"),
                    "render": "render.sh"}
            with self.assertRaises(ValueError):
                check_site_assets.write_manifest(kind, root)
            (root / "out/y.png").write_bytes(b"y")
            check_site_assets.write_manifest(kind, root)
            self.assertEqual(check_site_assets.staleness(kind, root), [])
            (root / "src/a.swift").write_text("changed"); (root / "src/b.swift").unlink(); (root / "src/c.swift").write_text("c")
            (root / "out/y.png").unlink()
            self.assertEqual(check_site_assets.staleness(kind, root),
                             ["missing output: out/y.png", "changed: src/a.swift", "removed: src/b.swift", "added: src/c.swift",
                              "removed: out/y.png"])
            (root / "manifest.json").unlink()
            self.assertEqual(check_site_assets.staleness(kind, root), ["no manifest: manifest.json"])

    def test_referenced_files_cover_pictures_video_poster_and_tracks(self):
        page = ('<img src="assets/a.png"><video poster="video/p.jpg"><source src="video/m.mp4">'
                '<track src="video/c.vtt"></video><link href="style.css"><a href="https://example.com/x.png">')
        self.assertEqual(referenced_files(page), {"assets/a.png", "video/p.jpg", "video/m.mp4", "video/c.vtt"})


if __name__ == "__main__":
    unittest.main()
