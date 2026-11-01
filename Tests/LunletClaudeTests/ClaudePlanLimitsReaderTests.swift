// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.09; US-32, AC-32.03; US-04, AC-04.03.
import Foundation
import Testing
import LunletCore
@testable import LunletClaude

@Suite struct ClaudePlanLimitsReaderTests {
    let now = Date(timeIntervalSince1970: 1_793_390_400)  // 2026-10-30T20:00:00Z
    var t: Int { Int(now.timeIntervalSince1970) }

    private func reader(state: String?, log: String? = nil) throws -> (ClaudePlanLimitsReader, StatusLineSandbox) {
        let box = try StatusLineSandbox()
        if let state { try Data(state.utf8).write(to: box.location.limits) }
        if let log { try Data(log.utf8).write(to: box.location.weeklyLog) }
        return (.init(location: box.location), box)
    }

    // Refs: US-33, AC-33.09.
    @Test func validReadingsBecomeProviderNeutralWindowsAndWeeklyRemaining() throws {
        let week = t + 3 * 86_400
        let state = "lunlet-claude-limits 1\nfive_hour 47 \(t + 3_600) \(t - 120)\nseven_day 13.5 \(week) \(t - 120)\n"
        let (reader, box) = try reader(state: state, log: "\(t - 86_400) 10 \(week)\n\(t - 3_600) 13 \(week)\n")
        defer { box.remove() }
        let limits = try #require(try reader.read(now: now))
        #expect(limits.fiveHour == LimitWindowReading(usedPercent: 47, resetsAt: Date(timeIntervalSince1970: Double(t + 3_600)),
                                                      at: Date(timeIntervalSince1970: Double(t - 120))))
        #expect(limits.sevenDay?.usedPercent == 13.5)
        #expect(limits.weekly.map(\.remaining) == [90, 87, 86.5])
        #expect(limits.weekly.allSatisfy { $0.resetAt == Date(timeIntervalSince1970: Double(week)) })
    }

    // Refs: US-33, AC-33.09; US-04, AC-04.03.
    @Test func invalidOrMissingValuesStayUnknown() throws {
        let (missing, empty) = try reader(state: nil); defer { empty.remove() }
        #expect(try missing.read(now: now) == nil)
        let bad = [
            "five_hour 101 \(t + 60) \(t)", "five_hour -1 \(t + 60) \(t)", "five_hour 1e2 \(t + 60) \(t)",
            "five_hour 5 \(t) \(t)",                         // reset not after the reading
            "five_hour 5 \(t + 6 * 3_600) \(t)",             // reset beyond one five-hour window
            "five_hour 5 \(t + 7_200) \(t + 3_600)",         // a reading from the future
            "five_hour 5 \(t + 60)", "five_hour 5 0\(t + 60) \(t)", "five_hour 5.1234567 \(t + 60) \(t)",
        ]
        for line in bad {
            let (reader, box) = try reader(state: "lunlet-claude-limits 1\n\(line)\n"); defer { box.remove() }
            let limits = try reader.read(now: now)
            #expect(limits?.fiveHour == nil && limits?.sevenDay == nil, "\(line)")
        }
        let (unknown, box) = try reader(state: "lunlet-claude-limits 2\nfive_hour 5 \(t + 60) \(t)\n"); defer { box.remove() }
        #expect(throws: ClaudeStatusLineFailure.self) { try unknown.read(now: now) }
        // A linked state file is refused, never followed.
        let (linked, other) = try reader(state: nil); defer { other.remove() }
        let target = other.scratch.appendingPathComponent("elsewhere")
        try Data("lunlet-claude-limits 1\nfive_hour 5 \(t + 60) \(t)\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: other.location.limits, withDestinationURL: target)
        #expect(throws: ClaudeStatusLineFailure.self) { try linked.read(now: now) }
    }

    // Refs: US-33, AC-33.09; US-32, AC-32.03.
    @Test func weeklyReadingsDropReplaysOlderWindowsAndExpiredHistory() throws {
        let week = t + 3 * 86_400, previous = week - 7 * 86_400
        let log = [
            "\(t - 9 * 86_400) 1 \(t - 3 * 86_400)",         // older than the estimator's input horizon
            "\(t - 5 * 86_400) 70 \(previous)",              // the previous window, kept for the changed-week guard
            "\(t - 4 * 86_400 + 60) 5 \(week)",              // this window
            "\(t - 2 * 86_400) 30 \(week)",
            "\(t - 2 * 86_400 + 600) 20 \(week)",            // an idle session's older response: lower in the same window
            "\(t - 86_400) 75 \(previous)",                  // a reset before its reading
            "\(t - 3_600) 31 \(week)", "\(t - 3_600) 40 \(week)",   // two values at one instant keep the higher
            "garbage", "\(t - 60) 32",
        ].joined(separator: "\n") + "\n"
        let (reader, box) = try reader(state: "lunlet-claude-limits 1\nseven_day 41 \(week) \(t - 30)\n", log: log)
        defer { box.remove() }
        let limits = try #require(try reader.read(now: now))
        #expect(limits.weekly.map(\.remaining) == [30, 95, 70, 60, 59])
        #expect(limits.fiveHour == nil)
        // The estimator accepts them as comparable readings of the identified window.
        let pace = WeeklyQuotaEstimator.pace(readings: limits.weekly, resetAt: Date(timeIntervalSince1970: Double(week)), now: now)
        #expect(pace.latest?.remaining == 59)
    }
}
