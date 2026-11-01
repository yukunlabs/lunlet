// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
import Foundation
import LunletCore

enum QuotaChartSegments {
    static func connects(_ a: QuotaReading, _ b: QuotaReading, calendar: Calendar = .current) -> Bool {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: a.at), to: calendar.startOfDay(for: b.at)).day ?? 0
        return days >= 0 && days <= 1 && abs(a.resetAt.timeIntervalSince(b.resetAt)) <= WeeklyQuotaEstimator.resetTimeTolerance
    }
}

struct QuotaResetMarker: Equatable {
    let at: Date
    let approximate: Bool
}

enum QuotaResetHitTesting {
    static func nearest(x: CGFloat, width: CGFloat, start: Date, reset: Date, markers: [QuotaResetMarker]) -> QuotaResetMarker? {
        guard width > 0, reset > start else { return nil }
        let span = reset.timeIntervalSince(start)
        return (markers + [.init(at: reset, approximate: false)])
            .filter { $0.at >= start && $0.at <= reset }
            .min { abs(width * $0.at.timeIntervalSince(start) / span - x) < abs(width * $1.at.timeIntervalSince(start) / span - x) }
            .flatMap { marker in
                abs(width * marker.at.timeIntervalSince(start) / span - x) <= 8 ? marker : nil
            }
    }

    static func label(_ marker: QuotaResetMarker) -> String {
        "Reset at " + marker.at.formatted(date: .abbreviated, time: .shortened) + (marker.approximate ? " (approx.)" : "")
    }
}

/// One render's trend. Chart points follow the selected range; the pace never does.
struct QuotaTrendDisplay {
    let points: [QuotaReading]
    let resets: [QuotaResetMarker]
    /// Nil until a successful account read identifies the window.
    let pace: QuotaPace?
}

private struct QuotaResetEvent {
    let marker: QuotaResetMarker
    let before: QuotaReading
    let after: QuotaReading
}

enum QuotaChartTimeline {
    static func start(now: Date, days: Int, calendar: Calendar = .current) -> Date? {
        guard (1...7).contains(days) else { return nil }
        return calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))
    }
    static func dates(now: Date, reset: Date, days: Int, calendar: Calendar = .current) -> [Date] {
        guard reset > now, let first = start(now: now, days: days, calendar: calendar) else { return [] }
        let end = calendar.startOfDay(for: reset)
        guard let count = calendar.dateComponents([.day], from: first, to: end).day, (0...15).contains(count) else { return [] }
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

/// In-memory account readings; they cannot establish remote-control authority.
struct WeeklyQuotaTrend: Equatable {
    private struct Identity: Equatable {
        let account: String
        let plan: String?
        let bucketID: String?
        let bucket: String
    }
    private var identity: Identity?
    /// The identified window's first reported reset, so repeated drift cannot move it unboundedly.
    private(set) var resetAt: Date?
    /// Successful reads of this account, bucket and plan across windows, within the estimator's input horizon.
    private(set) var readings: [QuotaReading] = []

    mutating func record(_ snapshot: AccountLimitsSnapshot) {
        guard let email = snapshot.identity?.email, !email.isEmpty,
              let weekly = AccountUsagePresentation.weekly(in: snapshot),
              snapshot.buckets.flatMap({ [$0.primary, $0.secondary] }).compactMap({ $0 })
                .filter({ $0.durationMinutes == 10_080 }).allSatisfy({ $0.usedPercent.map { $0 <= 100 } == true }),
              let remaining = weekly.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
              let reset = weekly.resetsAt, reset > snapshot.observedAt,
              reset.timeIntervalSince(snapshot.observedAt) <= 7 * 86_400 else {
            identity = nil; resetAt = nil; readings = []; return
        }
        if let latest = readings.last, snapshot.observedAt <= latest.at { return }
        let current = Identity(account: email, plan: snapshot.identity?.plan, bucketID: weekly.bucketID, bucket: weekly.bucketName)
        if identity != current { identity = current; resetAt = nil; readings = [] }
        if resetAt.map({ abs(reset.timeIntervalSince($0)) > WeeklyQuotaEstimator.resetTimeTolerance }) ?? true { resetAt = reset }
        readings.append(.init(at: snapshot.observedAt, remaining: remaining, resetAt: reset))
        let horizon = snapshot.observedAt.addingTimeInterval(-WeeklyQuotaEstimator.inputHorizon())
        readings.removeAll { $0.at < horizon }
        if readings.count > 2048 { readings.removeFirst(readings.count - 2048) }
    }

    /// Daily chart points and detected resets for the selected range, plus the pace from every comparable
    /// reading of the input horizon. Matching bucket, reset and plan is evidence, not account identity.
    func display(local: [LocalQuotaObservation], now: Date, since: Date = .distantPast) -> QuotaTrendDisplay {
        guard let identity, let resetAt, !readings.isEmpty else { return .init(points: [], resets: [], pace: nil) }
        let matching = identity.bucketID.map { bucket in
            local.filter {
                $0.bucketID == bucket && ($0.plan == nil || identity.plan == nil || $0.plan?.lowercased() == identity.plan?.lowercased())
            }
        } ?? []
        let comparable = WeeklyQuotaEstimator.consistentReadings(
            readings + matching.map { QuotaReading(at: $0.at, remaining: $0.remaining, resetAt: $0.resetAt) }, now: now)
        let pace = WeeklyQuotaEstimator.pace(readings: comparable, resetAt: resetAt, now: now)
        let chart = Self.chart(comparable, resetAt: resetAt, now: now, since: since)
        return .init(points: chart.points, resets: chart.resets, pace: pace)
    }

    /// Daily points and detected resets of comparable readings for one window, shared by every agent's chart.
    static func chart(_ comparable: [QuotaReading], resetAt: Date, now: Date, since: Date)
        -> (points: [QuotaReading], resets: [QuotaResetMarker]) {
        // The chart shows at most seven days, never the guard's extra day, and no unidentified later window.
        let start = max(since, now.addingTimeInterval(-WeeklyQuotaEstimator.week))
        let shown = comparable.filter {
            $0.at >= start && $0.resetAt.timeIntervalSince(resetAt) <= WeeklyQuotaEstimator.resetTimeTolerance
        }
        let events = Self.resetEvents(shown)
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.at) }
        let daily = groups.keys.sorted().compactMap { groups[$0]?.last }
        var unique: [Date: QuotaReading] = [:]
        for point in events.flatMap({ [$0.before, $0.after] }) + daily { unique[point.at] = point }
        return (unique.values.sorted { $0.at < $1.at }, events.map(\.marker))
    }

    private static func resetEvents(_ observations: [QuotaReading]) -> [QuotaResetEvent] {
        guard var previous = observations.first else { return [] }
        var events: [QuotaResetEvent] = []
        for next in observations.dropFirst() {
            let change = next.resetAt.timeIntervalSince(previous.resetAt)
            if abs(change) <= WeeklyQuotaEstimator.resetTimeTolerance { previous = next; continue }
            guard change > WeeklyQuotaEstimator.resetTimeTolerance else { continue }
            guard next.remaining > previous.remaining + 0.1 else { previous = next; continue }
            let inferredStart = next.resetAt.addingTimeInterval(-7 * 86_400)
            let scheduled = previous.resetAt >= previous.at && previous.resetAt <= next.at ? previous.resetAt : nil
            let inferred = inferredStart >= previous.at && inferredStart <= next.at ? inferredStart : nil
            events.append(.init(marker: .init(at: scheduled ?? inferred ?? next.at, approximate: scheduled == nil),
                                before: previous, after: next))
            previous = next
        }
        return events
    }
}

/// Compact forecast wording. `stale` marks an estimate kept after a failed account read.
enum QuotaForecastText {
    static func header(_ pace: QuotaPace?, stale: Bool, now: Date, calendar: Calendar = .current) -> String {
        guard let pace else { return "Awaiting account reading" }
        let asOf = pace.latest.map { latest -> String in
            if stale { return " · stale, as of " + time(latest.at, now: now, calendar: calendar) }
            return now.timeIntervalSince(latest.at) > 3600 ? " · as of " + time(latest.at, now: now, calendar: calendar) : ""
        } ?? ""
        switch pace.forecast {
        case .unavailable(.resetPassed): return "Reset due"
        case .unavailable(.staleReading):
            return pace.latest.map { "No reading since " + time($0.at, now: now, calendar: calendar) } ?? "No recent reading"
        case .unavailable: return "Awaiting account reading"
        case .tooEarly: return "Too early to estimate"
        case .exhausted: return "Exhausted" + asOf
        case .estimate(let estimate):
            let body: String
            if let runOut = estimate.runOut {
                body = "May run out ~" + day(runOut) + (estimate.earliestRunOut.map { " (earliest \(day($0)))" } ?? "")
            } else {
                let low = Int(estimate.remainingAtReset.lowerBound.rounded()), high = Int(estimate.remainingAtReset.upperBound.rounded())
                body = "Est. " + (low == high ? "\(low)" : "\(low)–\(high)") + "% at reset"
            }
            return (estimate.rough ? "Rough · " : "") + body + asOf
        }
    }

    /// Even budget versus remaining at the latest reading; never labeled a forecast.
    static func evenPace(_ pace: QuotaPace?, now: Date, calendar: Calendar = .current) -> String? {
        guard let even = pace?.evenPace, let latest = pace?.latest else { return nil }
        let remaining = Int(latest.remaining.rounded())
        let reading = now.timeIntervalSince(latest.at) > 3600 ? "\(remaining)% at " + time(latest.at, now: now, calendar: calendar)
            : "now \(remaining)%"
        return "Even pace \(Int(even.rounded()))% · " + reading
    }

    static func help(_ pace: QuotaPace?, stale: Bool, resetAt: Date?) -> String {
        let reset = resetAt.map { " Reset: " + $0.formatted(date: .abbreviated, time: .shortened) + "." } ?? ""
        guard let pace else { return "No successful account read identifies the weekly window yet." }
        let reading = pace.latest.map { " Latest reading: " + $0.at.formatted(date: .abbreviated, time: .shortened) + "." } ?? ""
        let staleNote = stale ? " The latest account read failed; this uses earlier readings of the same window." : ""
        switch pace.forecast {
        case .unavailable(.resetPassed): return "The reported reset has passed; a new account reading starts the next estimate." + reset
        case .unavailable(.staleReading): return "No estimate: the latest reading is more than a day old." + reading + reset
        case .unavailable: return "No estimate: no successful account read identifies the window of the latest reading." + reading
        case .tooEarly: return "Too early: fewer than six hours of this window's readings and no usable earlier window." + reading
        case .exhausted(let since):
            return "Observed at 0% since " + since.formatted(date: .abbreviated, time: .shortened) + "; not a projection." + reset
        case .estimate(let estimate):
            let low = estimate.remainingAtReset.lowerBound, high = estimate.remainingAtReset.upperBound
            var text = "Estimated remaining at reset: " + percent(low) + (low == high ? "" : "–" + percent(high))
                + ", from the pace of this account's readings over the past seven days. Not a guarantee."
            if let runOut = estimate.runOut { text += " Central run-out: " + runOut.formatted(date: .abbreviated, time: .shortened) + "." }
            if let earliest = estimate.earliestRunOut {
                text += " Earliest plausible run-out: " + earliest.formatted(date: .abbreviated, time: .shortened) + "."
            }
            if estimate.rough { text += " Rough: less than a day of this window's readings, without the previous window." }
            return text + reading + " Assumes no additional reset." + reset + staleNote
        }
    }

    static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened) : day(date)
    }

    private static func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    private static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + "%" }
}
