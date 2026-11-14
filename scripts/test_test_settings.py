#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-26, AC-26.01.
import unittest

from check_test_settings import main, problems


class TestSettingsTests(unittest.TestCase):
    def test_a_test_that_opens_its_own_settings_domain_is_refused(self):
        found = problems('let defaults = try #require(UserDefaults(suiteName: "com.example.test.\\(UUID())"))')
        self.assertEqual(found, [(1, "opens a settings domain of its own; use ScratchSettings.make")])
        self.assertEqual(len(problems("let suite = name\nlet defaults = UserDefaults(suiteName: suite)!")), 1)

    def test_the_shared_settings_of_the_test_process_are_refused_too(self):
        self.assertEqual(problems("let store = PreferencesStore(defaults: .standard)"),
                         [(1, "uses the shared settings of the test process; use ScratchSettings.make")])
        self.assertEqual(len(problems("UserDefaults.standard.set(1, forKey: \"k\")")), 1)

    def test_scratch_settings_and_other_uses_of_the_word_standard_pass(self):
        self.assertEqual(problems('let (defaults, suite) = try ScratchSettings.make("preferences")'), [])
        self.assertEqual(problems("PanelSegmentedStyle(size: .regular, scheme: .light, contrast: .standard)"), [])
        self.assertEqual(problems("// UserDefaults(suiteName:) leaves a file in the Library"), [])

    def test_the_tests_in_this_repository_keep_their_settings_out_of_the_library(self):
        self.assertEqual(main(), 0)


if __name__ == "__main__":
    unittest.main()
