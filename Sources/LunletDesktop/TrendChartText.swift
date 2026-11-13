// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.02, AC-32.03, AC-32.05, AC-32.06, AC-32.07, AC-32.08, AC-32.09.
// Refs: US-04, AC-04.02, AC-04.08, AC-04.19; US-33, AC-33.04, AC-33.09, AC-33.10.
import Foundation
import LunletCore

/// The floating chart's words: its title, the comparison with the even pace, the one sentence that states the
/// forecast, and the daily chart's footnote. The estimator's values are only worded here, never changed.
enum TrendChartText {
    /// The window and the agent, so a chart read on its own says whose limit it shows and how long its window is:
    /// a week, or the month of an account without a weekly limit.
    static func title(_ provider: SessionProvider, span: AllowanceSpan = .week) -> String {
        span.name + " limit · " + provider.displayName
    }

    /// The reset moment in the limit rows' wording: a time today, otherwise the weekday and time, or the month and
    /// day once it is more than six days away.
    static func resets(_ reset: Date, now: Date, calendar: Calendar = .current) -> String {
        "resets " + ClaudeLimitsText.moment(reset, now: now, calendar: calendar)
    }

    /// Remaining against the even budget at the latest reading's time; never labeled a forecast, and absent after a
    /// mid-window increase or without a comparable reading (AC-32.05). An older reading states its time (AC-32.07).
    static func now(_ pace: QuotaPace?, now: Date, calendar: Calendar = .current) -> String? {
        guard let even = pace?.evenPace, let latest = pace?.latest else { return nil }
        let remaining = Int(latest.remaining.rounded())
        let reading = now.timeIntervalSince(latest.at) > 3600
            ? "\(remaining)% left at " + QuotaForecastText.time(latest.at, now: now, calendar: calendar)
            : "Now \(remaining)% left"
        return reading + " · even pace \(Int(even.rounded()))%"
    }

    /// The forecast stated once in words (AC-32.09): about how much is left at reset with its range, or the run-out
    /// time with its earliest plausible time, labeled an estimate and rough where it is. Without a forecast the line
    /// is the reason the chart already names.
    static func estimate(_ pace: QuotaPace?, stale: Bool, now: Date, calendar: Calendar = .current) -> String {
        guard let pace, case .estimate(let estimate) = pace.forecast else {
            return QuotaForecastText.header(pace, stale: stale, now: now, calendar: calendar)
        }
        let body: String
        if let runOut = estimate.runOut {
            body = "may run out about " + QuotaForecastText.day(runOut, now: now, calendar: calendar)
                + (estimate.earliestRunOut.map { " (earliest " + QuotaForecastText.day($0, now: now, calendar: calendar) + ")" } ?? "")
        } else {
            let low = Int(estimate.remainingAtReset.lowerBound.rounded()), high = Int(estimate.remainingAtReset.upperBound.rounded())
            body = "about \(Int(estimate.central.rounded()))% left at reset" + (low == high ? "" : " (\(low)–\(high)%)")
        }
        let asOf = pace.latest.map { latest -> String in
            let time = QuotaForecastText.time(latest.at, now: now, calendar: calendar)
            if stale { return " · stale, as of " + time }
            return now.timeIntervalSince(latest.at) > 3600 ? " · as of " + time : ""
        } ?? ""
        return (estimate.rough ? "Rough estimate: " : "Estimate: ") + body + asOf
    }

    /// The daily chart's footnote in parts, the source first: where the numbers were recorded and, for cost, that
    /// they are estimates; records known to be incomplete say that the totals are at least this much. Claude Code's
    /// recorded usage is always such a lower bound (AC-33.04).
    static func dailyFootnote(provider: SessionProvider, cost: Bool, partial: Bool, partialPricing: Bool) -> [String] {
        let claude = provider == .claude, lowerBound = partial || claude
        let source = cost ? (claude ? "This Mac · API list-price estimate" : "This Mac · Estimated USD")
            : lowerBound ? "Recorded on this Mac" : "This Mac · local Codex records"
        return [source, lowerBound ? "totals are at least this much" : nil, cost && partialPricing ? "Partial pricing" : nil]
            .compactMap { $0 }
    }
}
