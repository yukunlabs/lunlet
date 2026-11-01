// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.09, AC-33.10; US-32, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
// Refs: US-19, AC-19.04, AC-19.05; US-04, AC-04.03, AC-04.12.
import Foundation
import LunletClaude
import LunletCore

/// Claude windows in the same terms as Codex: percent left, reset times and the reading's
/// age; the weekly forecast uses the shared Codex wording. Claude windows are never combined with Codex allowances.
enum ClaudeLimitsText {
    enum Window {
        case session, week
        var title: String { self == .session ? "Current session" : "This week" }
    }

    /// A window that applies now: nil when unknown or once its reset has passed.
    static func current(_ reading: LimitWindowReading?, now: Date) -> LimitWindowReading? {
        guard let reading, reading.resetsAt > now else { return nil }
        return reading
    }

    /// Remaining in a window that applies now, as "53% left"; a nearly exhausted window reads "<1% left", not 0%.
    static func left(_ reading: LimitWindowReading?, now: Date) -> String {
        guard let value = remaining(reading, now: now) else { return "—" }
        return (value > 0 && value < 1 ? "<1" : String(Int(value))) + "% left"
    }
    static func remaining(_ reading: LimitWindowReading?, now: Date) -> Double? {
        current(reading, now: now).map { min(100, max(0, 100 - $0.usedPercent)) }
    }

    static func resetLine(_ reading: LimitWindowReading?, now: Date, calendar: Calendar = .current) -> String {
        guard let reading else { return "reset —" }
        guard reading.resetsAt > now else { return "reset due" }
        return "resets " + moment(reading.resetsAt, now: now, calendar: calendar)
    }

    /// The reading's age, shown once it is more than a minute old.
    static func asOf(_ limits: ClaudePlanLimits?, now: Date, calendar: Calendar = .current) -> String? {
        guard let at = [limits?.fiveHour?.at, limits?.sevenDay?.at].compactMap({ $0 }).max(),
              now.timeIntervalSince(at) > 60 else { return nil }
        return "as of " + moment(at, now: now, calendar: calendar)
    }

    /// The weekly window's pace from every comparable reading; nil until a reading identifies the window.
    static func pace(_ limits: ClaudePlanLimits?, now: Date) -> QuotaPace? {
        guard let week = limits?.sevenDay else { return nil }
        return WeeklyQuotaEstimator.pace(readings: limits?.weekly ?? [week.remaining], resetAt: week.resetsAt, now: now)
    }

    /// Recorded token categories, so cache reads never dominate a single total (AC-33.10).
    static func breakdown(_ amount: LocalUsageAmount?, compact: Bool = false) -> String? {
        guard let categories = amount?.breakdown else { return nil }
        func count(_ value: Int64) -> String { value.formatted(.number.notation(.compactName)) }
        if compact { return "in " + count(categories.input) + " · out " + count(categories.output) }
        return ["in " + count(categories.input), "out " + count(categories.output),
                "cache write " + count(categories.cacheWrite), "cache read " + count(categories.cacheRead)].joined(separator: " · ")
    }
    static func spokenBreakdown(_ amount: LocalUsageAmount?) -> String? {
        guard let categories = amount?.breakdown else { return nil }
        return "input \(categories.input), output \(categories.output), cache write \(categories.cacheWrite), "
            + "cache read \(categories.cacheRead) tokens"
    }

    /// A time today, or an abbreviated weekday and time otherwise.
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
