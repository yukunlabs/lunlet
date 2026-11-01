// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
import Foundation
import Testing
import LunletCore
import LunletCodex
@testable import LunletDesktop

private extension QuotaPace {
    var estimate: QuotaPaceEstimate? { if case .estimate(let value) = forecast { return value }; return nil }
}

struct WeeklyQuotaTrendTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func chartBreaksAtResetsAndMissingDays() {
        let day = Calendar.current.startOfDay(for: start)
        let reset = day.addingTimeInterval(7 * 86_400)
        func point(_ hours: Double, _ resetAt: Date) -> QuotaReading {
            .init(at: day.addingTimeInterval(hours * 3600), remaining: 50, resetAt: resetAt)
        }
        #expect(QuotaChartSegments.connects(point(1, reset), point(25, reset.addingTimeInterval(90))))
        #expect(!QuotaChartSegments.connects(point(1, reset), point(2, reset.addingTimeInterval(86_400))))
        #expect(!QuotaChartSegments.connects(point(1, reset), point(49, reset)))
    }
    // AC-32.03: the chart never bridges a gap or a reset, and the shaded range spans only the estimate.
    @Test func observedSegmentsBreakAtGapsAndResetsAndTheRangeStaysBetweenItsLines() {
        let day = Calendar.current.startOfDay(for: start)
        let reset = day.addingTimeInterval(7 * 86_400), next = reset.addingTimeInterval(7 * 86_400)
        func point(_ hours: Double, _ remaining: Double, _ resetAt: Date) -> QuotaReading {
            .init(at: day.addingTimeInterval(hours * 3600), remaining: remaining, resetAt: resetAt)
        }
        let segments = QuotaObservedSegments.split([point(1, 90, reset), point(20, 80, reset), point(70, 60, reset),
                                                    point(71, 100, next)])
        #expect(segments.map(\.count) == [2, 1, 1])
        let lines = QuotaEstimateGeometry.Lines(central: [point(0, 60, reset), point(10, 40, reset)],
                                                upper: [point(0, 60, reset), point(10, 50, reset)],
                                                lower: [point(0, 60, reset), point(5, 0, reset), point(10, 0, reset)])
        let band = QuotaEstimateGeometry.band(lines)
        #expect(band.map(\.at) == [0.0, 5, 10].map { day.addingTimeInterval($0 * 3600) })
        #expect(band.allSatisfy { $0.low <= $0.high } && band[1].low == 0 && band[1].high == 55)
    }
    @Test func idealLineUsesTheFullWeeklyWindow() {
        let reset = start.addingTimeInterval(7 * 86_400)
        #expect(WeeklyQuotaEstimator.idealRemaining(at: start, resetAt: reset) == 100)
        #expect(WeeklyQuotaEstimator.idealRemaining(at: start.addingTimeInterval(3.5 * 86_400), resetAt: reset) == 50)
        #expect(WeeklyQuotaEstimator.idealRemaining(at: reset, resetAt: reset) == 0)
        #expect(WeeklyQuotaEstimator.idealRemaining(at: start.addingTimeInterval(-1), resetAt: reset) == nil)
    }
    @Test func hoveringEitherResetLineIdentifiesItsTime() throws {
        let reset = start.addingTimeInterval(7 * 86_400)
        let historical = QuotaResetMarker(at: start.addingTimeInterval(2 * 86_400), approximate: true)
        let historicalX = 200.0 * 2 / 7
        let hit = try #require(QuotaResetHitTesting.nearest(x: historicalX + 3, width: 200, start: start, reset: reset, markers: [historical]))
        #expect(hit == historical)
        #expect(QuotaResetHitTesting.label(hit).hasPrefix("Reset at "))
        #expect(QuotaResetHitTesting.label(hit).contains("approx."))
        let upcoming = try #require(QuotaResetHitTesting.nearest(x: 198, width: 200, start: start, reset: reset, markers: [historical]))
        #expect(upcoming.at == reset && !upcoming.approximate)
        #expect(QuotaResetHitTesting.nearest(x: 120, width: 200, start: start, reset: reset, markers: [historical]) == nil)
    }
    private func sample(hours: Double, remaining: Double, email: String = "owner@example.invalid", resetOffset: Double = 7 * 86_400) throws -> AccountLimitsSnapshot {
        let reset = Int(start.timeIntervalSince1970 + resetOffset)
        let limits = Data("""
        {"rateLimits":{"limitId":"codex","secondary":{"usedPercent":\(100 - remaining),"windowDurationMins":10080,"resetsAt":\(reset)}}}
        """.utf8)
        let account = Data("""
        {"account":{"type":"chatgpt","email":"\(email)","planType":"pro"}}
        """.utf8)
        return try AccountLimitsDecoder.decode(limits, observedAt: start.addingTimeInterval(hours * 3600), accountData: account)
    }
    @Test func smallResetTimeDriftKeepsOneWindowButALaterResetStartsANewOne() throws {
        // AC-32.01, AC-32.03: reported reset drift within tolerance is the same window.
        var trend = WeeklyQuotaTrend()
        for (h, remaining, drift) in [(0.0, 80.0, 0.0), (0.5, 70.0, 40.0), (1.0, 60.0, -30.0)] {
            trend.record(try sample(hours: h, remaining: remaining, resetOffset: 7 * 86_400 + drift))
        }
        #expect(trend.readings.count == 3)
        #expect(trend.resetAt == start.addingTimeInterval(7 * 86_400))
        trend.record(try sample(hours: 1.5, remaining: 50, resetOffset: 7 * 86_400 + 301))
        // Earlier windows stay as pace evidence; the identified window moves.
        #expect(trend.readings.count == 4)
        #expect(trend.resetAt == start.addingTimeInterval(7 * 86_400 + 301))
    }
    /// Two earlier days of matching history, before the in-memory reading at 72 hours.
    private func dailyHistory(remaining: [Double] = [90, 75]) -> [LocalQuotaObservation] {
        let reset = start.addingTimeInterval(7 * 86_400)
        return zip([0.0, 36.0], remaining).map {
            LocalQuotaObservation(at: start.addingTimeInterval($0.0 * 3600), resetAt: reset, remaining: $0.1, bucketID: "codex", plan: "pro")
        }
    }
    @Test func forecastFollowsReadingFreshnessAndUseRatherThanChartSampling() throws {
        // AC-32.07, AC-32.08: a single reading with an inferred window start can estimate; age, not sampling,
        // removes it; and flat readings project the current remaining.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let now = start.addingTimeInterval(72 * 3600)
        #expect(trend.display(local: dailyHistory(), now: now).pace?.estimate != nil)
        #expect(trend.display(local: [], now: now).pace?.estimate != nil)
        #expect(trend.display(local: dailyHistory(), now: now.addingTimeInterval(2 * 3600)).pace?.estimate != nil)
        let stale = try #require(trend.display(local: dailyHistory(), now: now.addingTimeInterval(25 * 3600)).pace)
        #expect(stale.forecast == .unavailable(.staleReading))
        var flat = WeeklyQuotaTrend()
        flat.record(try sample(hours: 72, remaining: 90))
        let estimate = try #require(flat.display(local: dailyHistory(remaining: [90, 90]), now: now).pace?.estimate)
        #expect(estimate.remainingAtReset == 90...90 && estimate.runOut == nil)
    }
    @Test func displayedForecastRecalculatesWhenANewObservationArrives() throws {
        // AC-32.02: a new allowance observation replaces the earlier projection.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let before = try #require(trend.display(local: dailyHistory(), now: start.addingTimeInterval(72 * 3600)).pace?.estimate)
        #expect(before.runOut == nil && abs(before.central - 20) < 0.001)
        trend.record(try sample(hours: 96, remaining: 20))
        let after = try #require(trend.display(local: dailyHistory(), now: start.addingTimeInterval(96 * 3600)).pace?.estimate)
        #expect(after.runOut != nil && after.central == 0)
    }
    @Test func forecastIsIdenticalAcrossOneAndSevenDayRanges() throws {
        // AC-32.02, AC-32.03: forecast inputs never depend on the displayed range.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 150, remaining: 40))
        let reset = start.addingTimeInterval(7 * 86_400)
        let local = stride(from: 1.0, to: 150, by: 2).map {
            LocalQuotaObservation(at: start.addingTimeInterval($0 * 3600), resetAt: reset, remaining: (100 - $0 * 0.4).rounded(),
                                  bucketID: "codex", plan: "pro")
        }
        let now = start.addingTimeInterval(150 * 3600)
        let oneDay = trend.display(local: local, now: now, since: try #require(QuotaChartTimeline.start(now: now, days: 1)))
        let sevenDays = trend.display(local: local, now: now, since: try #require(QuotaChartTimeline.start(now: now, days: 7)))
        #expect(oneDay.pace?.estimate != nil)
        #expect(oneDay.pace == sevenDays.pace)
        #expect(oneDay.points.count < sevenDays.points.count)
    }
    @Test func matchingLocalQuotaHistoryFeedsTheChartAndInterleavedWindowsAreRejected() throws {
        // AC-32.01, AC-32.03: a different reset between same-window readings suggests a second account.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let reset = start.addingTimeInterval(7 * 86_400)
        let history: [LocalQuotaObservation] = [
            .init(at: start, resetAt: reset, remaining: 90, bucketID: "codex", plan: "pro"),
            .init(at: start.addingTimeInterval(36 * 3600), resetAt: reset, remaining: 75, bucketID: "codex", plan: "pro"),
            .init(at: start.addingTimeInterval(40 * 3600), resetAt: reset.addingTimeInterval(3600), remaining: 10, bucketID: "codex", plan: "pro")
        ]
        let display = trend.display(local: history, now: start.addingTimeInterval(72 * 3600))
        #expect(display.points.map(\.remaining) == [90, 75, 60])
        #expect(display.pace?.forecast == .tooEarly)
        #expect(trend.display(local: Array(history.prefix(2)), now: start.addingTimeInterval(72 * 3600)).pace?.estimate != nil)
        let previous = LocalQuotaObservation(at: start.addingTimeInterval(-3600), resetAt: start.addingTimeInterval(3600), remaining: 10, bucketID: "codex", plan: "pro")
        let chart = trend.display(local: history + [previous], now: start.addingTimeInterval(72 * 3600)).points
        #expect(chart.count <= 5)
        #expect(chart.last?.resetAt == reset)
    }
    @Test func conflictingLocalSnapshotsAreNotUsedForProjection() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let reset = start.addingTimeInterval(7 * 86_400)
        let records: [LocalQuotaObservation] = [
            .init(at: start, resetAt: reset, remaining: 90, bucketID: "codex", plan: "pro"),
            .init(at: start, resetAt: reset, remaining: 80, bucketID: "codex", plan: "pro")
        ]
        #expect(trend.display(local: records, now: start.addingTimeInterval(72 * 3600)).points.count == 1)
    }
    @Test func differentResetIsVisibleButNotInCurrentWindowEstimate() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let old = LocalQuotaObservation(at: start, resetAt: start.addingTimeInterval(3 * 86_400), remaining: 99, bucketID: "codex", plan: "pro")
        let later = LocalQuotaObservation(at: start.addingTimeInterval(24 * 3600), resetAt: old.resetAt, remaining: 1, bucketID: "codex", plan: "pro")
        let now = start.addingTimeInterval(72 * 3600)
        let points = trend.display(local: [old, later], now: now).points
        let reset = try #require(trend.resetAt)
        #expect(points.filter { abs($0.resetAt.timeIntervalSince(reset)) <= WeeklyQuotaEstimator.resetTimeTolerance }.count == 1)
        #expect(points.count >= 2)
    }
    @Test func priorWindowInformsPaceRegardlessOfTheDisplayedRange() throws {
        // AC-32.03: an earlier window counts only within-window use, and the range never hides the estimate.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let priorReset = start.addingTimeInterval(-86_400)
        let records: [LocalQuotaObservation] = [
            .init(at: start.addingTimeInterval(-3 * 86_400), resetAt: priorReset, remaining: 90, bucketID: "codex", plan: "pro"),
            .init(at: start.addingTimeInterval(-2 * 86_400), resetAt: priorReset, remaining: 70, bucketID: "codex", plan: "pro")
        ]
        let now = start.addingTimeInterval(72 * 3600)
        let full = trend.display(local: records, now: now)
        #expect(full.pace?.estimate != nil)
        #expect(trend.display(local: records, now: now, since: start).pace == full.pace)
        #expect(trend.display(local: records, now: now, since: start).points.count < full.points.count)
    }
    @Test func forecastUsesFullResolutionReadingsNotDailyChartPoints() throws {
        // AC-32.02: the chart keeps one point per day; the pace sees every reading.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let priorReset = start.addingTimeInterval(-86_400)
        let day = Calendar.current.startOfDay(for: start.addingTimeInterval(-3 * 86_400)).addingTimeInterval(3600)
        let rows = [
            LocalQuotaObservation(at: day, resetAt: priorReset, remaining: 90, bucketID: "codex", plan: "pro"),
            LocalQuotaObservation(at: day.addingTimeInterval(3600), resetAt: priorReset, remaining: 70, bucketID: "codex", plan: "pro")
        ]
        let now = start.addingTimeInterval(72 * 3600)
        let withRows = trend.display(local: rows, now: now)
        #expect(withRows.points.count == 2)
        #expect(withRows.pace?.estimate != nil)
        #expect(withRows.pace != trend.display(local: [rows[1]], now: now).pace)
    }
    @Test func forecastIncludesConsumptionImmediatelyAfterAReset() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 20, remaining: 66))
        let reset = start.addingTimeInterval(7 * 86_400)
        let rows = [
            LocalQuotaObservation(at: start, resetAt: start.addingTimeInterval(6 * 86_400), remaining: 49, bucketID: "codex", plan: "pro"),
            LocalQuotaObservation(at: start.addingTimeInterval(0.1 * 3600), resetAt: reset, remaining: 100, bucketID: "codex", plan: "pro"),
            LocalQuotaObservation(at: start.addingTimeInterval(4 * 3600), resetAt: reset, remaining: 69, bucketID: "codex", plan: "pro")
        ]
        let now = start.addingTimeInterval(20 * 3600)
        let displayed = trend.display(local: rows, now: now).points
        #expect(displayed.contains { $0.remaining == 100 })
        let estimate = try #require(trend.display(local: rows, now: now).pace?.estimate)
        let exhaustion = try #require(estimate.runOut)
        #expect(exhaustion.timeIntervalSince(now) > 36 * 3600)
        #expect(exhaustion.timeIntervalSince(now) < 42 * 3600)
    }
    @Test func resetMarkersUseTheWindowStartOrAnApproximateObservation() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 25, remaining: 99, resetOffset: 192 * 3600))
        let old = LocalQuotaObservation(at: start, resetAt: start.addingTimeInterval(100 * 3600), remaining: 49, bucketID: "codex", plan: "pro")
        let new = LocalQuotaObservation(at: start.addingTimeInterval(24.1 * 3600), resetAt: start.addingTimeInterval(192 * 3600), remaining: 100, bucketID: "codex", plan: "pro")
        let markers = trend.display(local: [old, new], now: start.addingTimeInterval(25 * 3600), since: start).resets
        #expect(markers == [.init(at: start.addingTimeInterval(24 * 3600), approximate: true)])
        let laterOld = LocalQuotaObservation(at: start.addingTimeInterval(24.05 * 3600), resetAt: old.resetAt, remaining: 49, bucketID: "codex", plan: "pro")
        let approximate = trend.display(local: [laterOld, new], now: start.addingTimeInterval(25 * 3600), since: start).resets
        #expect(approximate == [.init(at: new.at, approximate: true)])
    }
    @Test func resetMarkersIgnoreSmallResetTimestampDrift() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 25, remaining: 99, resetOffset: 192 * 3600))
        let rows = [
            LocalQuotaObservation(at: start, resetAt: start.addingTimeInterval(100 * 3600), remaining: 100, bucketID: "codex", plan: "pro"),
            LocalQuotaObservation(at: start.addingTimeInterval(23 * 3600), resetAt: start.addingTimeInterval(100 * 3600 + 90), remaining: 49, bucketID: "codex", plan: "pro"),
            LocalQuotaObservation(at: start.addingTimeInterval(24.1 * 3600), resetAt: start.addingTimeInterval(192 * 3600), remaining: 100, bucketID: "codex", plan: "pro")
        ]
        let markers = trend.display(local: rows, now: start.addingTimeInterval(25 * 3600), since: start).resets
        #expect(markers == [.init(at: start.addingTimeInterval(24 * 3600), approximate: true)])
    }
    @Test func forecastCombinesSmallResetTimestampDrift() throws {
        // AC-32.03: readings whose resets differ by a minute are one window.
        let reset = start.addingTimeInterval(7 * 86_400)
        let readings = [QuotaReading(at: start, remaining: 100, resetAt: reset.addingTimeInterval(-60)),
                        QuotaReading(at: start.addingTimeInterval(86_400), remaining: 80, resetAt: reset)]
        let pace = WeeklyQuotaEstimator.pace(readings: readings, resetAt: reset, now: start.addingTimeInterval(86_400))
        let runOut = try #require(pace.estimate?.runOut)
        #expect(abs(runOut.timeIntervalSince(start.addingTimeInterval(5 * 86_400))) < 600)
    }
    @Test func dailyChartCollapsesManySamplesWithoutLosingTheCurrentReading() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let reset = start.addingTimeInterval(7 * 86_400)
        let rows = (0..<120).map { index in
            LocalQuotaObservation(at: start.addingTimeInterval(Double(index) * 1800), resetAt: reset,
                                  remaining: 90 - Double(index) * 0.2, bucketID: "codex", plan: "pro")
        }
        let chart = trend.display(local: rows, now: start.addingTimeInterval(72 * 3600)).points
        #expect(chart.count <= 8)
        #expect(chart.last?.remaining == 60)
    }
    @Test func chartKeepsLatestObservationForEachDay() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 72, remaining: 60))
        let reset = start.addingTimeInterval(7 * 86_400)
        let values = [(0.0, 90.0), (0.1, 89.0), (0.2, 88.0)].map {
            LocalQuotaObservation(at: start.addingTimeInterval($0.0 * 3600), resetAt: reset,
                                  remaining: $0.1, bucketID: "codex", plan: "pro")
        }
        let result = trend.display(local: values, now: start.addingTimeInterval(72 * 3600)).points
        #expect(result.contains { $0.remaining == 88 })
        #expect(!result.contains { $0.remaining == 90 })
        #expect(!result.contains { $0.remaining == 89 })
    }
    @Test func timelineIncludesEveryDateThroughReset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"))
        let reset = try #require(ISO8601DateFormatter().date(from: "2026-11-04T06:35:00Z"))
        let days = QuotaChartTimeline.dates(now: now, reset: reset, days: 5, calendar: calendar)
        #expect(days.count == 12)
        #expect(calendar.component(.day, from: try #require(days.first)) == 24)
        #expect(calendar.component(.day, from: try #require(days.last)) == 4)
    }
    @Test func selectedRangeExcludesOlderInMemoryAndLocalObservations() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 0, remaining: 95))
        trend.record(try sample(hours: 72, remaining: 80))
        trend.record(try sample(hours: 144, remaining: 60))
        let now = start.addingTimeInterval(144 * 3600)
        let since = start.addingTimeInterval(72 * 3600)
        let old = LocalQuotaObservation(at: start.addingTimeInterval(24 * 3600), resetAt: start.addingTimeInterval(7 * 86_400), remaining: 90, bucketID: "codex", plan: "pro")
        let points = trend.display(local: [old], now: now, since: since).points
        #expect(!points.isEmpty && points.allSatisfy { $0.at >= since })
        // The guard's extra eighth day never reaches the chart, even without a selected range.
        let eighth = LocalQuotaObservation(at: now.addingTimeInterval(-7.5 * 86_400), resetAt: start, remaining: 30,
                                           bucketID: "codex", plan: "pro")
        #expect(!trend.display(local: [eighth], now: now).points.contains { $0.at == eighth.at })
    }
    @Test func accountChangesClearReadingsButWindowsAndIncreasesKeepThem() throws {
        // AC-32.03: readings from another account are never pace evidence; earlier windows are.
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 0, remaining: 80))
        trend.record(try sample(hours: 1, remaining: 70, email: "another@example.invalid"))
        #expect(trend.readings.map(\.remaining) == [70])
        trend.record(try sample(hours: 2, remaining: 60, email: "another@example.invalid", resetOffset: 7 * 86_400 + 3600))
        #expect(trend.readings.map(\.remaining) == [70, 60])
        trend.record(try sample(hours: 3, remaining: 90, email: "another@example.invalid", resetOffset: 7 * 86_400 + 3600))
        #expect(trend.readings.map(\.remaining) == [70, 60, 90])
        trend.record(try sample(hours: 2, remaining: 80, email: "another@example.invalid", resetOffset: 7 * 86_400 + 3600))
        #expect(trend.readings.map(\.remaining) == [70, 60, 90])
        // Readings older than the estimator's input horizon are pruned.
        trend.record(try sample(hours: 200, remaining: 50, email: "another@example.invalid", resetOffset: 9 * 86_400))
        #expect(trend.readings.map(\.remaining) == [50])
    }
    @Test func missingIdentityAndInvalidPercentDoNotInventAnObservation() throws {
        var trend = WeeklyQuotaTrend()
        trend.record(try sample(hours: 0, remaining: 80))
        let missingIdentity = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":\(Int(start.addingTimeInterval(7 * 86_400).timeIntervalSince1970))}}}
        """.utf8), observedAt: start.addingTimeInterval(10))
        trend.record(missingIdentity)
        #expect(trend.readings.isEmpty && trend.resetAt == nil)
        trend.record(try sample(hours: 1, remaining: -10))
        #expect(trend.readings.isEmpty && trend.display(local: [], now: start.addingTimeInterval(3600)).pace == nil)
    }
    @Test func headerAndFooterTextNameEachForecastState() throws {
        // AC-32.05 through AC-32.08: compact state wording, qualifiers and the even-pace comparison.
        let now = start
        let latest = QuotaReading(at: now, remaining: 58, resetAt: now.addingTimeInterval(4 * 86_400))
        func pace(_ forecast: QuotaPaceForecast, latest: QuotaReading? = latest, even: Double? = 64.2) -> QuotaPace {
            .init(forecast: forecast, latest: latest, evenPace: even)
        }
        func text(_ value: QuotaPace?, stale: Bool = false, at date: Date = now) -> String {
            QuotaForecastText.header(value, stale: stale, now: date)
        }
        let range = QuotaPaceEstimate(remainingAtReset: 15.4...34.6, central: 25, runOut: nil, earliestRunOut: nil,
                                      latestRunOut: nil, rough: false)
        #expect(text(pace(.estimate(range))) == "Est. 15–35% at reset")
        let runOut = now.addingTimeInterval(50 * 3600), earliest = now.addingTimeInterval(30 * 3600)
        let running = QuotaPaceEstimate(remainingAtReset: 0...10, central: 0, runOut: runOut, earliestRunOut: earliest,
                                        latestRunOut: nil, rough: true)
        let day = { (date: Date) in date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        #expect(text(pace(.estimate(running))) == "Rough · May run out ~\(day(runOut)) (earliest \(day(earliest)))")
        let later = now.addingTimeInterval(2 * 3600)
        #expect(text(pace(.estimate(range)), at: later).hasSuffix(" · as of " + QuotaForecastText.time(now, now: later)))
        #expect(!text(pace(.estimate(range)), at: now.addingTimeInterval(3000)).contains("as of"))
        #expect(text(pace(.estimate(range)), stale: true).hasSuffix(" · stale, as of " + QuotaForecastText.time(now, now: now)))
        #expect(text(pace(.tooEarly)) == "Too early to estimate")
        #expect(text(pace(.exhausted(since: now))) == "Exhausted")
        #expect(text(pace(.unavailable(.staleReading)), at: now.addingTimeInterval(26 * 3600))
            == "No reading since " + day(now))
        #expect(text(pace(.unavailable(.resetPassed), latest: nil, even: nil)) == "Reset due")
        #expect(text(nil) == "Awaiting account reading")
        #expect(text(pace(.unavailable(.unidentifiedWindow), latest: nil, even: nil)) == "Awaiting account reading")
        #expect(QuotaForecastText.evenPace(pace(.tooEarly), now: now) == "Even pace 64% · now 58%")
        #expect(QuotaForecastText.evenPace(pace(.tooEarly, even: nil), now: now) == nil)
        #expect(QuotaForecastText.help(pace(.estimate(running)), stale: true, resetAt: latest.resetAt).contains("Rough"))
        #expect(QuotaForecastText.help(pace(.estimate(range)), stale: true, resetAt: latest.resetAt).contains("account read failed"))
    }
    @Test func estimateLinesStartAtTheLatestReadingAndClipToTheVisibleRange() {
        // AC-32.06, AC-32.07: the shaded range and the central line start at the latest reading.
        let reset = start.addingTimeInterval(100 * 3600)
        let latest = QuotaReading(at: start, remaining: 50, resetAt: reset)
        let estimate = QuotaPaceEstimate(remainingAtReset: 0...20, central: 5, runOut: nil,
                                         earliestRunOut: start.addingTimeInterval(80 * 3600), latestRunOut: nil, rough: false)
        let lines = QuotaEstimateGeometry.lines(estimate, from: latest, reset: reset, visibleFrom: start.addingTimeInterval(-3600))
        #expect(lines.central.first == latest && lines.central.last?.remaining == 5)
        #expect(lines.upper.map(\.remaining) == [50, 20])
        #expect(lines.lower.map(\.remaining) == [50, 0, 0])
        let clipped = QuotaEstimateGeometry.lines(estimate, from: latest, reset: reset, visibleFrom: start.addingTimeInterval(50 * 3600))
        #expect(clipped.upper.first?.at == start.addingTimeInterval(50 * 3600))
        #expect(clipped.upper.first.map { abs($0.remaining - 35) < 1e-9 } == true)
    }
}
