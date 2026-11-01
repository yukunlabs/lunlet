// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
import Foundation

/// One official remaining-allowance reading of a fixed-length quota window. Provider-independent:
/// callers pass only comparable readings (same account bucket and plan), never token or cost data.
public struct QuotaReading: Equatable, Hashable, Sendable {
    public let at: Date
    /// Remaining percentage, 0...100.
    public let remaining: Double
    public let resetAt: Date
    public init(at: Date, remaining: Double, resetAt: Date) {
        self.at = at; self.remaining = remaining; self.resetAt = resetAt
    }
}

/// A projected range of remaining allowance, not a guarantee.
public struct QuotaPaceEstimate: Equatable, Sendable {
    /// Remaining percentage at reset; a single value when the readings show no use.
    public let remainingAtReset: ClosedRange<Double>
    public let central: Double
    /// Central projection's run-out before reset.
    public let runOut: Date?
    /// Run-out at the high and low ends of the pace range.
    public let earliestRunOut: Date?
    public let latestRunOut: Date?
    /// Built from less than a day of current-window evidence alone.
    public let rough: Bool
    public init(remainingAtReset: ClosedRange<Double>, central: Double, runOut: Date?, earliestRunOut: Date?,
                latestRunOut: Date?, rough: Bool) {
        self.remainingAtReset = remainingAtReset; self.central = central; self.runOut = runOut
        self.earliestRunOut = earliestRunOut; self.latestRunOut = latestRunOut; self.rough = rough
    }
}

public enum QuotaPaceForecast: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// No comparable reading of the identified window.
        case noReading
        case resetPassed
        /// The latest reading of the window is more than a day old.
        case staleReading
        /// Later readings report a window that the identifying account read does not confirm.
        case unidentifiedWindow
    }
    case unavailable(Reason)
    case tooEarly
    /// Observed at 0% since the given reading; this is not a projection.
    case exhausted(since: Date)
    case estimate(QuotaPaceEstimate)
}

public struct QuotaPace: Equatable, Sendable {
    public let forecast: QuotaPaceForecast
    /// The latest comparable reading of the window; projections start here.
    public let latest: QuotaReading?
    /// Even-budget remaining at `latest.at`; omitted after a mid-window increase.
    public let evenPace: Double?
    public init(forecast: QuotaPaceForecast, latest: QuotaReading?, evenPace: Double?) {
        self.forecast = forecast; self.latest = latest; self.evenPace = evenPace
    }
}

/// Pace from official readings. Thresholds are calibrated for seven-day windows.
public enum WeeklyQuotaEstimator {
    /// Reset timestamps from the same reported window may differ slightly across snapshots.
    public static let resetTimeTolerance: TimeInterval = 300
    public static let week: TimeInterval = 7 * 86_400
    private static let hour: TimeInterval = 3600, day: TimeInterval = 86_400
    private static let minimumTrailingCoverage = 48 * hour
    private static let minimumWindowEvidence = 6 * hour
    private static let staleAfter = day
    /// Relative uncertainty of the projected pace, widened when only this window informs it.
    private static let band = 0.45

    /// Pace uses readings from one trailing window. The extra day feeds only the changed-week guard's
    /// comparison with the same hours one window earlier, never the pace itself.
    public static func inputHorizon(window: TimeInterval = week) -> TimeInterval { window + day }

    /// An even allowance budget within the reset window, independent of actual usage.
    public static func idealRemaining(at date: Date, resetAt: Date, window: TimeInterval = week) -> Double? {
        let remaining = resetAt.timeIntervalSince(date)
        guard remaining.isFinite, window > 0, (0...window).contains(remaining) else { return nil }
        return 100 * remaining / window
    }

    /// Valid readings within the input horizon; readings that disagree at one instant are dropped.
    public static func consistentReadings(_ readings: [QuotaReading], now: Date, window: TimeInterval = week) -> [QuotaReading] {
        let earliest = now.addingTimeInterval(-inputHorizon(window: window))
        let valid = readings.filter {
            $0.at.timeIntervalSinceReferenceDate.isFinite && $0.resetAt.timeIntervalSinceReferenceDate.isFinite
                && $0.remaining.isFinite && (0...100).contains($0.remaining) && $0.at <= now && $0.at >= earliest
                && $0.at < $0.resetAt && $0.resetAt.timeIntervalSince($0.at) <= window + resetTimeTolerance
        }
        return Dictionary(grouping: valid, by: \.at).values.compactMap { copies -> QuotaReading? in
            let first = copies[0]
            return copies.allSatisfy { $0.remaining == first.remaining && sameWindow($0.resetAt, first.resetAt) } ? first : nil
        }.sorted { $0.at < $1.at }
    }

    public static func pace(readings: [QuotaReading], resetAt: Date, now: Date,
                            window: TimeInterval = week, precision: Double = 1) -> QuotaPace {
        func unavailable(_ reason: QuotaPaceForecast.Reason) -> QuotaPace {
            .init(forecast: .unavailable(reason), latest: nil, evenPace: nil)
        }
        guard now.timeIntervalSinceReferenceDate.isFinite, resetAt.timeIntervalSinceReferenceDate.isFinite,
              window > 0, precision.isFinite, precision >= 0 else { return unavailable(.noReading) }
        guard resetAt > now else { return unavailable(.resetPassed) }
        let clean = consistentReadings(readings, now: now, window: window)
        let segments = segments(clean, precision: precision)
        guard let last = segments.last else { return unavailable(.noReading) }
        // A later reported reset may be a new window that no account read has confirmed yet.
        if last.reset.timeIntervalSince(resetAt) > resetTimeTolerance { return unavailable(.unidentifiedWindow) }
        guard let index = segments.lastIndex(where: { sameWindow($0.reset, resetAt) }) else { return unavailable(.noReading) }
        let current = segments[index].points
        let first = current[0], latest = current[current.count - 1]
        let increased = increasedWithinWindow(clean.filter { sameWindow($0.resetAt, resetAt) }, precision: precision)
        let even = increased ? nil : idealRemaining(at: latest.at, resetAt: resetAt, window: window)
        func result(_ forecast: QuotaPaceForecast) -> QuotaPace { .init(forecast: forecast, latest: latest, evenPace: even) }
        guard now.timeIntervalSince(latest.at) <= staleAfter else { return result(.unavailable(.staleReading)) }
        if latest.remaining <= 0, let zero = current.first(where: { $0.remaining <= 0 }) { return result(.exhausted(since: zero.at)) }

        // Resets move forward within one account; an earlier reset after a later one suggests a second
        // account on this Mac, so earlier evidence is ignored.
        var interleaved = index != segments.count - 1, latestReset = Date.distantPast
        for segment in segments[...index] {
            if latestReset.timeIntervalSince(segment.reset) > resetTimeTolerance { interleaved = true }
            latestReset = max(latestReset, segment.reset)
        }
        // Pace uses only readings from the trailing window, segmented as if they were the whole input. The
        // extra day of the input horizon feeds only the same-hours comparison below.
        let trailingStart = latest.at.addingTimeInterval(-window)
        let recentSegments = Self.segments(clean.filter { $0.at >= trailingStart }, precision: precision)
        let recentIndex = recentSegments.lastIndex { $0.points.contains { $0.at == latest.at } } ?? -1
        let recent = evidence(recentSegments, through: recentIndex, interleaved: interleaved, window: window)
        let all = evidence(segments, through: index, interleaved: interleaved, window: window)

        let anchoredStart = windowStart(segments, index, window: window)
        let paceStart = anchoredStart ?? first.at
        let elapsed = latest.at.timeIntervalSince(paceStart)
        let span = latest.at.timeIntervalSince(first.at)
        let consumed = (anchoredStart == nil ? first.remaining : 100) - latest.remaining
        let sinceStart: Double? = elapsed >= minimumWindowEvidence ? consumed / elapsed : nil
        let trailing = rate(recent, from: trailingStart, to: latest.at)
        let trailingRate: Double? = trailing.covered >= minimumTrailingCoverage ? trailing.rate : nil
        // Changed-week guard: compare this window's use with the same hours one window earlier, or after
        // a day with the earlier window's pace within the trailing period.
        var changed = false
        if elapsed >= minimumWindowEvidence {
            let same = rate(all.filter { $0.end <= first.at }, from: paceStart.addingTimeInterval(-window), to: trailingStart)
            let previous = rate(recent.filter { $0.end <= first.at }, from: trailingStart, to: paceStart)
            var expected: Double?
            if same.covered >= 0.8 * elapsed { expected = same.rate * elapsed }
            else if elapsed >= day, previous.covered >= day { expected = previous.rate * elapsed }
            if let expected { changed = consumed > 2 * expected + 5 || consumed < expected / 2 - 5 }
        }
        let pace: Double, evidence: TimeInterval, windowOnly: Bool
        if let trailingRate, !changed { (pace, evidence, windowOnly) = (trailingRate, trailing.covered, false) }
        else if let sinceStart { (pace, evidence, windowOnly) = (sinceStart, elapsed, true) }
        else { return result(.tooEarly) }
        let rough = windowOnly && span < day
        let horizon = resetAt.timeIntervalSince(latest.at)
        if pace <= 0, evidence >= day {
            let value = latest.remaining
            return result(.estimate(.init(remainingAtReset: value...value, central: value, runOut: nil,
                                          earliestRunOut: nil, latestRunOut: nil, rough: rough)))
        }
        // Range: relative pace uncertainty plus reading precision over at most a day of evidence.
        let spread = band * (windowOnly ? (rough ? 1.6 : 1.2) : 1)
        let precisionRate = precision / max(min(span, day), hour)
        let slow = max(0, pace * (1 - spread) - precisionRate), fast = pace * (1 + spread) + precisionRate
        func remaining(_ rate: Double) -> Double { max(0, latest.remaining - rate * horizon) }
        func runOut(_ rate: Double) -> Date? {
            guard rate > 0 else { return nil }
            let date = latest.at.addingTimeInterval(latest.remaining / rate)
            return date < resetAt ? date : nil
        }
        return result(.estimate(.init(remainingAtReset: remaining(fast)...remaining(slow), central: remaining(pace),
                                      runOut: runOut(pace), earliestRunOut: runOut(fast), latestRunOut: runOut(slow),
                                      rough: rough)))
    }

    private struct Interval { let start: Date; let end: Date; let used: Double }
    private struct Segment { let reset: Date; var points: [QuotaReading] }

    /// Within-segment use plus each window's inferred start, through the current segment. Intervals between
    /// segments contain a reset or an increase and are never counted.
    private static func evidence(_ segments: [Segment], through index: Int, interleaved: Bool, window: TimeInterval) -> [Interval] {
        guard segments.indices.contains(index) else { return [] }
        var intervals: [Interval] = []
        for i in interleaved ? [index] : Array(0...index) {
            let points = segments[i].points
            // An interval that starts exhausted is blocked demand, not pace evidence.
            for (a, b) in zip(points, points.dropFirst()) where b.at > a.at && a.remaining > 0 {
                intervals.append(.init(start: a.at, end: b.at, used: a.remaining - b.remaining))
            }
            if let start = windowStart(segments, i, window: window) {
                intervals.append(.init(start: start, end: points[0].at, used: 100 - points[0].remaining))
            }
        }
        return intervals
    }

    private static func sameWindow(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) <= resetTimeTolerance }

    /// A reset change or a rise beyond reading precision starts a segment. Within a segment, readings
    /// are clamped to the running minimum, so the interval containing a reset jump is never counted.
    private static func segments(_ readings: [QuotaReading], precision: Double) -> [Segment] {
        var segments: [Segment] = []
        var minimum = 0.0
        for reading in readings {
            if let last = segments.last, sameWindow(reading.resetAt, last.reset), reading.remaining <= minimum + precision + 1e-9 {
                minimum = min(minimum, reading.remaining)
            } else {
                segments.append(.init(reset: reading.resetAt, points: [])); minimum = reading.remaining
            }
            segments[segments.count - 1].points.append(.init(at: reading.at, remaining: minimum, resetAt: reading.resetAt))
        }
        return segments
    }

    private static func increasedWithinWindow(_ readings: [QuotaReading], precision: Double) -> Bool {
        var minimum = Double.infinity
        for reading in readings {
            if reading.remaining > minimum + precision + 1e-9 { return true }
            minimum = min(minimum, reading.remaining)
        }
        return false
    }

    /// Reset minus one window as the 100% start of a window's first segment, for pace only. A reading
    /// of another window after that time, or an earlier segment of the same window, contradicts it.
    private static func windowStart(_ segments: [Segment], _ index: Int, window: TimeInterval) -> Date? {
        let segment = segments[index]
        let start = segment.reset.addingTimeInterval(-window)
        guard let first = segment.points.first, start < first.at else { return nil }
        if index > 0 {
            let previous = segments[index - 1]
            guard !sameWindow(previous.reset, segment.reset), let end = previous.points.last, end.at <= start else { return nil }
        }
        return start
    }

    /// Calendar rate in percentage points per second over [from, to], prorating straddling intervals.
    private static func rate(_ intervals: [Interval], from: Date, to: Date) -> (rate: Double, covered: TimeInterval) {
        var used = 0.0, covered: TimeInterval = 0
        for interval in intervals where interval.end > from && interval.start < to {
            let span = interval.end.timeIntervalSince(interval.start)
            let overlap = min(interval.end, to).timeIntervalSince(max(interval.start, from))
            guard span > 0, overlap > 0 else { continue }
            used += interval.used * overlap / span; covered += overlap
        }
        return (covered > 0 ? used / covered : 0, covered)
    }
}
