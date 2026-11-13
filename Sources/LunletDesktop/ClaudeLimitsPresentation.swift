// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.09, AC-33.10; US-32, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
// Refs: US-19, AC-19.04, AC-19.05; US-04, AC-04.03, AC-04.12.
import Foundation
import LunletClaude
import LunletCore

/// Claude's weekly window in the same terms as Codex: percent left, reset time and the reading's age; the forecast
/// uses the shared Codex wording. Claude limits are never combined with Codex allowances.
enum ClaudeLimitsText {
    static let weekTitle = "This week"
    /// The Limits card's help (AC-33.09, AC-33.11).
    static let cardHelp = "Percent left and the reset time as Claude Code reported them through Lunlet's status line: official values, "
        + "not estimates. The estimate beside them is drawn from those readings and is never a guarantee. Model-specific "
        + "weekly limits are only in Claude Code's own /usage. Hover for the weekly trend and daily usage on this Mac."
    /// What adding the status line changes and how it is undone (AC-33.08).
    static let connectHelp = "Lunlet adds its status line to Claude Code's settings.json while Claude Code is "
        + "selected, unless you undid it; an existing status line keeps running. A custom status line hides most of "
        + "Claude Code's footer keyboard hints. Lunlet keeps only percent used and reset times and reads no credentials. "
        + "Undo, or turning Claude Code off in Settings › Agents, restores the previous setting exactly."

    /// What the weekly figure reads when there is no reading, on screen and for assistive tools alike (AC-24.02).
    static func missing(connected: Bool) -> String { connected ? "Unknown" : "Not connected" }

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
        guard let at = limits?.sevenDay?.at, now.timeIntervalSince(at) > 60 else { return nil }
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

    /// A time today; otherwise the day and the time (AC-04.01).
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : day(date, now: now, calendar: calendar)
    }

    /// A day and a time: the abbreviated weekday within six days of now, either way; farther away a weekday no longer
    /// tells the day, so the month and day stand in for it, as for the reset of a 30-day window (AC-04.01).
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        guard abs(days) > 6 else { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + date.formatted(date: .omitted, time: .shortened)
    }
}
