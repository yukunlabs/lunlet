#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.04; US-11, AC-11.05; US-29, AC-29.02.
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


if __name__ == "__main__":
    unittest.main()
