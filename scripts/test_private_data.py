#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-34, AC-34.02.
import unittest

from check_private_data import main, problems


class PrivateDataTests(unittest.TestCase):
    def kinds(self, text):
        return [kind for _, kind in problems(text)]

    def test_a_real_home_folder_is_refused_and_a_placeholder_is_not(self):
        self.assertEqual(self.kinds("built in /Users/jane/project"), ["a home folder"])
        self.assertEqual(self.kinds("cache at /home/jane/.cache"), ["a home folder"])
        for line in ["/Users/<account>/Library", "/Users/$USER/x", "/Users/Shared/x", "/Users/synthetic/project",
                     "/Users/someone/project", "~/Library/Preferences"]:
            self.assertEqual(self.kinds(line), [], line)

    def test_a_real_mail_address_is_refused_and_reserved_ones_are_not(self):
        self.assertEqual(self.kinds("write to jane@workplace.test"), ["a mail address"])
        for line in ["owner@example.invalid", "a@example.com", "1+name@users.noreply.github.com",
                     "https://user:password@slack.com/api/auth.test", "git@github.com:owner/repository.git"]:
            self.assertEqual(self.kinds(line), [], line)

    def test_keys_and_tokens_are_refused(self):
        for line in ["-----BEGIN PRIVATE KEY-----", "xoxb-1234567890-abcdefghij", "ghp_" + "a" * 36,
                     "github_pat_" + "a" * 30, "sk-" + "a" * 24, "1234567890:" + "a" * 35]:
            self.assertEqual(self.kinds("value " + line), ["a key or token"], line)

    def test_a_fixture_that_says_it_is_synthetic_passes(self):
        self.assertEqual(self.kinds('"sk-synthetic-secret-value-1234", // a synthetic key'), [])
        self.assertEqual(self.kinds('"-----BEGIN PRIVATE KEY-----\\nsynthetic\\n-----END PRIVATE KEY-----"'), [])

    def test_a_problem_names_its_line_without_repeating_the_value(self):
        found = problems("first line\nmail jane@workplace.test\n")
        self.assertEqual(found, [(2, "a mail address")])

    def test_the_committed_tree_holds_none(self):
        self.assertEqual(main(), 0)


if __name__ == "__main__":
    unittest.main()
