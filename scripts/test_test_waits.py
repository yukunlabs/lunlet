#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.02.
import unittest

from check_test_waits import main, problems


class TestWaitsTests(unittest.TestCase):
    def test_short_deadlines_and_polling_loops_are_refused(self):
        self.assertEqual(len(problems("let deadline = ContinuousClock.now + .seconds(10)")), 1)
        self.assertEqual(len(problems("#expect(done.wait(timeout: .now() + 2) == .success)")), 1)
        loop = "for _ in 0..<2_000 {\n    if ready { return }\n    try await Task.sleep(for: .milliseconds(1))\n}"
        self.assertEqual(len(problems(loop)), 1)

    def test_roomy_waits_and_deliberately_short_ones_pass(self):
        self.assertEqual(problems("let deadline = ContinuousClock.now + .seconds(60)"), [])
        self.assertEqual(problems("for _ in 0..<20_000 {\n    try await Task.sleep(for: .milliseconds(1))\n}"), [])
        self.assertEqual(problems("let quiet = ContinuousClock.now + .seconds(1) // short on purpose: nothing may arrive"), [])
        # A counted loop that does not sleep, or sleeps without leaving early, repeats or samples; it is not a wait.
        self.assertEqual(problems("for _ in 0..<4_200 { _ = try signal(spool) }\nawait monitor.refresh()"), [])
        self.assertEqual(problems("for _ in 0..<4 {\n    seen.insert(picture)\n    try await Task.sleep(for: .milliseconds(330))\n}\nreturn seen.count"), [])
        one_line = "for _ in 0..<3 { await monitor.refresh() }\nlet late = 1\ntry await Task.sleep(for: .milliseconds(5))\nreturn late"
        self.assertEqual(problems(one_line), [])

    def test_the_repository_has_no_wait_a_slow_machine_would_fail(self):
        self.assertEqual(main(), 0)


if __name__ == "__main__":
    unittest.main()
