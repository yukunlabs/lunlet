#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.04; US-11, AC-11.05; US-29, AC-29.02; US-28, AC-28.04.
import tempfile
import unittest
from pathlib import Path

from check_traceability import audit


REQUIREMENTS = """# Requirements
| EPIC-01 | Example outcome | US-01, US-02 |
### US-01: Confirmed behavior
Status: Confirmed.
- **AC-01.01**: Given a verified state, When input arrives, Then check it.
### US-02: Unconfirmed behavior
Status: Proposed.
- **AC-02.01**: Given a proposal, When reviewed, Then wait for confirmation.
"""


class TraceabilityTests(unittest.TestCase):
    def check(self, source, requirements=REQUIREMENTS, filename="example.swift", licensed=True):
        with tempfile.TemporaryDirectory(prefix="lunlet-trace-test-") as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "docs/requirements.md").write_text(requirements)
            if licensed and not filename.endswith(".md"):
                mark = "#" if filename.endswith((".py", ".sh", ".yml")) else "//"
                source = f"{mark} SPDX-FileCopyrightText: 2026 example\n{mark} SPDX-License-Identifier: 0BSD\n" + source
            path = root / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            return audit(root, [Path("docs/requirements.md"), Path(filename)])

    # Refs: US-29, AC-29.02.
    def test_owned_source_needs_the_license_header_and_generated_code_keeps_its_own(self):
        source = "// Refs: US-01, AC-01.01.\nimport Foundation\n"
        self.assertEqual(self.check(source, licensed=False), ["example.swift: missing SPDX license header"])
        self.assertEqual(self.check(source, filename="Generated/frame.pb.swift", licensed=False), [])

    def test_confirmed_parent_and_criterion_are_accepted(self):
        self.assertEqual(self.check("// Refs: US-01, AC-01.01.\nimport Foundation\n"), [])

    def test_missing_unknown_unconfirmed_or_mismatched_references_are_rejected(self):
        for source in [
            "import Foundation\n",
            "// Refs: US-99, AC-99.01.\n",
            "// Refs: US-02, AC-02.01.\n",
            "// Refs: US-01, AC-02.01.\n",
            "// Refs: US-01.\n",
            "// Refs: AC-01.01.\n",
        ]:
            with self.subTest(source=source):
                self.assertNotEqual(self.check(source), [])

    def test_duplicate_criterion_ids_in_the_specification_are_rejected(self):
        spec = REQUIREMENTS + "\n- **AC-01.01**: Duplicate identifier.\n"
        self.assertNotEqual(self.check("// Refs: US-01, AC-01.01.\n", spec), [])

    def test_repository_language_rule_is_checked_without_printing_content(self):
        source = "// Refs: US-01, AC-01.01.\n// " + chr(0x4E2D) + "\n"
        issues = self.check(source)
        self.assertNotEqual(issues, [])
        self.assertNotIn(chr(0x4E2D), "\n".join(issues))

    def test_documentation_also_follows_the_language_rule(self):
        self.assertEqual(self.check("English guidance.\n", filename="guide.md"), [])
        self.assertNotEqual(self.check(chr(0x4E2D) + "\n", filename="guide.md"), [])

    def test_each_story_needs_exactly_one_primary_epic(self):
        missing = REQUIREMENTS.replace("US-01, US-02 |", "US-01 |")
        duplicated = REQUIREMENTS.replace("| EPIC-01 |", "| EPIC-02 | Other outcome | US-02 |\n| EPIC-01 |")
        unknown = REQUIREMENTS.replace("US-01, US-02 |", "US-01, US-02, US-99 |")
        for spec in [missing, duplicated, unknown]:
            with self.subTest(spec=spec.splitlines()[1]):
                self.assertNotEqual(self.check("// Refs: US-01, AC-01.01.\n", spec), [])

    def test_application_metadata_also_requires_confirmed_references(self):
        self.assertNotEqual(self.check("<plist/>\n", filename="Info.plist"), [])
        self.assertEqual(self.check("<!-- Refs: US-01, AC-01.01. -->\n<plist/>\n", filename="Info.plist"), [])

    def test_product_page_sources_also_require_confirmed_references(self):
        for filename in ["index.html", "style.css", "app.js"]:
            with self.subTest(filename=filename):
                self.assertNotEqual(self.check("/* Source without traceability */\n", filename=filename), [])
                self.assertEqual(self.check("/* Refs: US-01, AC-01.01. */\n", filename=filename), [])

    def test_protocol_schemas_also_require_confirmed_references(self):
        self.assertNotEqual(self.check('syntax = "proto2";\n', filename="frame.proto"), [])
        self.assertEqual(self.check('// Refs: US-01, AC-01.01.\nsyntax = "proto2";\n', filename="frame.proto"), [])


    def tree(self, files):
        with tempfile.TemporaryDirectory(prefix="lunlet-trace-test-") as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "docs/requirements.md").write_text(REQUIREMENTS)
            for name, text in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            return audit(root, [Path("docs/requirements.md")] + [Path(name) for name in files])

    def readmes(self, **changed):
        switcher = "[English](README.md) [Chinese](README.zh-CN.md) [Japanese](README.ja.md)\n"
        body = ('<img src="docs/hero.jpg" alt="{word}">\n\n## {word}\n\n{word} [setup](docs/messaging.md).\n\n'
                "```sh\nscripts/build-app.sh --preview\n```\n")
        files = {"README.md": switcher + body.format(word="Install"),
                 "README.zh-CN.md": switcher + body.format(word=chr(0x5B89) + chr(0x88C5)),
                 "README.ja.md": switcher + body.format(word=chr(0x5C0E) + chr(0x5165))}
        for name, edit in changed.items():
            name = {"english": "README.md", "chinese": "README.zh-CN.md", "japanese": "README.ja.md"}[name]
            if edit is None:
                del files[name]
            else:
                files[name] = edit(files[name])
        return files

    # Refs: US-28, AC-28.04.
    def test_a_readme_translation_may_use_its_own_language_when_it_mirrors_the_readme(self):
        self.assertEqual(self.tree(self.readmes()), [])

    def test_only_the_declared_translations_are_exempt_from_the_language_rule(self):
        files = self.readmes()
        files["docs/README.zh-CN.md"] = files["README.zh-CN.md"]
        self.assertEqual(self.tree(files), ["docs/README.zh-CN.md: repository language rule violated"])

    def test_a_translation_that_drops_or_changes_a_part_of_the_readme_is_rejected(self):
        edits = {
            "sections": lambda text: text + "\n## Extra\n",
            "pictures": lambda text: text.replace("docs/hero.jpg", "docs/other.jpg"),
            "links": lambda text: text.replace("docs/messaging.md", "docs/skins.md"),
            "commands": lambda text: text.replace("--preview", "--release"),
        }
        for part, edit in edits.items():
            with self.subTest(part=part):
                self.assertEqual(self.tree(self.readmes(chinese=edit)),
                                 ["README.zh-CN.md: translation does not mirror README.md (" + part + ")"])

    def test_a_change_to_the_readme_alone_is_rejected_for_every_translation(self):
        issues = self.tree(self.readmes(english=lambda text: text + "\n## Privacy\n"))
        self.assertEqual(issues, ["README.ja.md: translation does not mirror README.md (sections)",
                                  "README.zh-CN.md: translation does not mirror README.md (sections)"])

    def test_a_declared_translation_must_exist_and_every_readme_links_the_others(self):
        self.assertEqual(self.tree(self.readmes(japanese=None)), ["README.ja.md: translation is missing"])
        unlinked = self.tree(self.readmes(english=lambda text: text.replace("[Japanese](README.ja.md)", "Japanese")))
        self.assertEqual(unlinked, ["README.md: does not link README.ja.md"])


if __name__ == "__main__":
    unittest.main()
