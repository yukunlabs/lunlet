#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.02.
import unittest

from changed_areas import areas


class ChangedAreasTests(unittest.TestCase):
    def test_prose_the_page_and_the_python_checks_need_neither_slow_area(self):
        for paths in [["README.md"], ["README.zh-CN.md", "docs/privacy.md"], ["docs/requirements.md", "docs/feasibility.md"],
                      ["website/index.html", "docs/assets/screenshots/hero-overview.jpg"],
                      ["scripts/check_traceability.py", "scripts/test_traceability.py"],
                      [".github/ISSUE_TEMPLATE/bug.yml", ".github/pull_request_template.md"]]:
            self.assertEqual(areas(paths), {"swift": False, "release": False}, paths)

    def test_source_tests_and_the_package_need_the_swift_modules(self):
        for path in ["Sources/LunletCore/DiagnosticLog.swift", "Tests/LunletCoreTests/X.swift", "Package.swift",
                     "Package.resolved", "scripts/test-core.sh", "scripts/swift-common.sh", "Resources/Info.plist"]:
            self.assertTrue(areas(["README.md", path])["swift"], path)

    def test_what_the_release_tooling_reads_needs_the_release_tooling(self):
        for path in ["docs/releases.md", "NOTICE.md", "LICENSE", "scripts/package-release.sh", "scripts/build-app.sh",
                     "scripts/test_release.py", "scripts/check_appcast.py", "scripts/test_appcast.py",
                     "scripts/rehearse_update.py", "scripts/test_rehearse_update.py",
                     "Resources/Info.plist", "Package.resolved"]:
            self.assertTrue(areas([path])["release"], path)
        # Release notes are read when a feed is made, not by the tooling's tests.
        self.assertFalse(areas(["docs/release-notes/v0.2.0.md"])["release"])

    def test_the_workflow_its_rules_and_anything_unknown_run_everything(self):
        for path in [".github/workflows/validate.yml", "scripts/changed_areas.py", "scripts/check-repository.sh",
                     "a-new-top-level-file", "tools/new.sh", ".gitignore"]:
            self.assertEqual(areas([path]), {"swift": True, "release": True}, path)

    def test_no_known_change_runs_everything(self):
        self.assertEqual(areas(None), {"swift": True, "release": True})
        self.assertEqual(areas([]), {"swift": False, "release": False})


if __name__ == "__main__":
    unittest.main()
