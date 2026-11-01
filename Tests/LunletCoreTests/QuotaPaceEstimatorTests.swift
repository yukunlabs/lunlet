// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.02, AC-32.03, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
import Foundation
import Testing
import LunletCore

private extension QuotaPace {
    var estimate: QuotaPaceEstimate? { if case .estimate(let value) = forecast { return value }; return nil }
}

/// Synthetic readings only. Times are hours from an arbitrary origin; windows last 168 hours.
@Suite struct QuotaPaceEstimatorTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ hours: Double) -> Date { origin.addingTimeInterval(hours * 3600) }
    private func reading(_ hours: Double, _ remaining: Double, reset: Double) -> QuotaReading {
        .init(at: at(hours), remaining: remaining, resetAt: at(reset))
    }
    private func pace(_ readings: [QuotaReading], reset: Double, now: Double) -> QuotaPace {
        WeeklyQuotaEstimator.pace(readings: readings, resetAt: at(reset), now: at(now))
    }
    private func near(_ date: Date?, _ hours: Double, within seconds: TimeInterval = 1) -> Bool {
        date.map { abs($0.timeIntervalSince(at(hours))) <= seconds } ?? false
    }

    @Test func dailyCycleAveragesOutAcrossTwoIdenticalWorkWeeks() throws {
        // AC-32.02, AC-32.06: a trailing calendar week makes nights and work hours one stable pace.
        // Work hours since the window began: weekdays, nine to six, at 1.2 points an hour. Written as a plain loop
        // because the hosted Swift 6.3 compiler cannot type-check the one-line closure form in reasonable time.
        func used(_ hour: Int) -> Double {
            let window = hour / 168 * 168
            var workHours = 0
            for elapsed in window..<hour {
                let weekday = (elapsed % 168) / 24, hourOfDay = elapsed % 24
                if weekday < 5 && hourOfDay >= 9 && hourOfDay < 18 { workHours += 1 }
            }
            return Double(workHours) * 1.2
        }
        let readings = (0..<336).map { reading(Double($0), (100 - used($0)).rounded(), reset: Double($0 / 168 * 168 + 168)) }
        let weekly = 5 * 9 * 1.2, truth = 100 - weekly
        for hour in 174...252 {
            let result = pace(Array(readings.prefix(hour + 1)), reset: 336, now: Double(hour))
            let estimate = try #require(result.estimate)
            let latest = try #require(result.latest)
            #expect(!estimate.rough)
            let implied = (latest.remaining - estimate.central) / Double(336 - hour)
            #expect(abs(implied - weekly / 168) < 0.05 * weekly / 168, "hour \(hour)")
            if [180, 204, 228].contains(hour) { #expect(estimate.remainingAtReset.contains(truth), "hour \(hour)") }
        }
    }

    @Test func resetIntervalAndTimeAtZeroAreNeverCountedAsUse() throws {
        // AC-32.03: neither the reset jump nor the hours spent exhausted dilute the pace.
        let previous = [reading(0, 100, reset: 168), reading(50, 50, reset: 168), reading(100, 0, reset: 168)]
        let plateau = [reading(110, 0, reset: 168), reading(140, 0, reset: 168), reading(167, 0, reset: 168)]
        let current = [reading(170, 98, reset: 336), reading(200, 68, reset: 336)]
        let result = pace(previous + plateau + current, reset: 336, now: 200)
        let estimate = try #require(result.estimate)
        // Every counted interval, including the inferred window start, uses one point per hour.
        #expect(near(estimate.runOut, 268))
        #expect(estimate.central == 0 && !estimate.rough)
        #expect(result == pace(previous + current, reset: 336, now: 200))
    }

    @Test func midWindowIncreaseStartsANewSegmentAndOmitsEvenPace() throws {
        // AC-32.03, AC-32.05: a rise within the same reported window is not consumption.
        let before = [reading(0, 100, reset: 168), reading(60, 40, reset: 168)]
        let increased = pace(before + [reading(62, 100, reset: 168), reading(80, 82, reset: 168)], reset: 168, now: 80)
        #expect(increased.evenPace == nil)
        #expect(near(try #require(increased.estimate).runOut, 162))
        let steady = pace(before + [reading(80, 22, reset: 168)], reset: 168, now: 80)
        let evenPace = try #require(steady.evenPace), expectedPace: Double = 100 * 88 / 168
        #expect(abs(evenPace - expectedPace) < 1e-9)
        #expect(steady.latest?.remaining == 22)
    }

    @Test func changedWeekGuardComparesTheSameHoursOneWeekEarlier() throws {
        // AC-32.06: much heavier use than last week ignores the earlier window and is rough for a day.
        let readings = (0...198).map { hour -> QuotaReading in
            let h = Double(hour)
            return hour < 168 ? reading(h, 100 - 0.2 * h, reset: 168) : reading(h, 100 - 1.5 * (h - 168), reset: 336)
        }
        let early = try #require(pace(Array(readings.prefix(181)), reset: 336, now: 180).estimate)
        #expect(early.rough)
        #expect(near(early.runOut, 180 + 82 / 1.5, within: 60))
        let later = try #require(pace(readings, reset: 336, now: 198).estimate)
        #expect(!later.rough)
        #expect(near(later.runOut, 198 + 55 / 1.5, within: 60))
    }

    @Test func eighthDayFeedsOnlyTheSameHoursComparison() throws {
        // AC-32.02, AC-32.06: pace uses the trailing seven days only; the extra day informs the guard.
        let readings = (0...260).map { hour -> QuotaReading in
            let h = Double(hour)
            return hour < 168 ? reading(h, 100 - 0.4 * h, reset: 168) : reading(h, 100 - 0.4 * (h - 168), reset: 336)
        }
        let altered = readings.map {
            $0.at < at(92) ? QuotaReading(at: $0.at, remaining: max(0, $0.remaining - 30), resetAt: $0.resetAt) : $0
        }
        let full = pace(readings, reset: 336, now: 260)
        #expect(full.estimate != nil)
        #expect(full == pace(readings.filter { $0.at >= at(92) }, reset: 336, now: 260))
        #expect(full == pace(altered, reset: 336, now: 260))
        // Last week's first hours were as heavy as this week's, then a mid-window increase restored the
        // allowance. Only eighth-day readings show that; without them the inferred start suggests light use.
        let previous = [reading(0, 100, reset: 168), reading(6, 60, reset: 168)]
            + (7...167).map { reading(Double($0), 100 - 0.2 * Double($0 - 7), reset: 168) }
        let current = (168...180).map { reading(Double($0), 100 - 1.5 * Double($0 - 168), reset: 336) }
        let comparable = try #require(pace(previous + current, reset: 336, now: 180).estimate)
        #expect(!comparable.rough && comparable.runOut == nil)
        let sevenDays = try #require(pace((previous + current).filter { $0.at >= at(12) }, reset: 336, now: 180).estimate)
        #expect(sevenDays.rough && sevenDays.runOut != nil)
    }

    @Test func precisionNoiseWithoutEarlierEvidenceIsTooEarly() {
        // AC-32.08: under six hours of current-window readings and no earlier window: too early.
        let noisy = [reading(0, 100, reset: 168), reading(1, 99.5, reset: 168), reading(2, 100, reset: 168),
                     reading(3, 99.2, reset: 168), reading(4, 99.8, reset: 168)]
        let result = pace(noisy, reset: 168, now: 4)
        #expect(result.forecast == .tooEarly)
        // Noise within reading precision is not a mid-window increase.
        #expect(result.evenPace != nil)
        #expect(pace(noisy + [reading(5, 98, reset: 168)], reset: 168, now: 5).forecast == .tooEarly)
    }

    @Test func noDecreaseAcrossADayEqualsCurrentRemaining() throws {
        // AC-32.08: at least a day without a decrease projects the current remaining, with no range.
        let flat = (0...30).map { reading(Double($0), 100, reset: 168) }
        let estimate = try #require(pace(flat, reset: 168, now: 30).estimate)
        #expect(estimate.remainingAtReset == 100...100 && estimate.central == 100)
        #expect(estimate.runOut == nil && estimate.earliestRunOut == nil)
        // Less than a day of flat readings is still a rough range, not a certainty.
        let short = try #require(pace(Array(flat.prefix(21)), reset: 168, now: 20).estimate)
        #expect(short.rough && short.remainingAtReset.lowerBound < 100)
    }

    @Test func zeroReadingIsObservedExhaustionNotAProjection() {
        // AC-32.08: a 0% reading shows the observed run-out.
        let readings = [reading(0, 100, reset: 168), reading(30, 40, reset: 168), reading(50, 0, reset: 168), reading(55, 0, reset: 168)]
        let result = pace(readings, reset: 168, now: 56)
        #expect(result.forecast == .exhausted(since: at(50)))
        #expect(result.latest?.at == at(55))
    }

    @Test func staleOrPassedOrUnconfirmedWindowsStateTheirReason() throws {
        // AC-32.07: older than an hour still projects from that reading; over a day, a passed reset, or a
        // later unconfirmed window produces no forecast and a reason.
        let readings = [reading(0, 100, reset: 168), reading(10, 90, reset: 168), reading(30, 70, reset: 168)]
        let twoHours = pace(readings, reset: 168, now: 32)
        #expect(twoHours.estimate != nil && twoHours.latest?.at == at(30))
        #expect(pace(readings, reset: 168, now: 54).estimate != nil)
        let stale = pace(readings, reset: 168, now: 54.5)
        #expect(stale.forecast == .unavailable(.staleReading) && stale.latest?.at == at(30))
        #expect(pace(readings, reset: 168, now: 169).forecast == .unavailable(.resetPassed))
        let newer = pace(readings + [reading(31, 100, reset: 199)], reset: 168, now: 32)
        #expect(newer.forecast == .unavailable(.unidentifiedWindow) && newer.latest == nil)
        // Drift within five minutes is the same window.
        #expect(pace(readings + [reading(31, 69, reset: 168.05)], reset: 168, now: 32).estimate != nil)
    }

    @Test func interleavedResetsIgnoreEarlierEvidence() throws {
        // AC-32.03: alternating resets suggest two accounts; their readings are never combined.
        let own = (0...12).map { reading(24 + Double($0), 90 - Double($0), reset: 168) }
        #expect(pace(own, reset: 168, now: 36).estimate != nil)
        let other = (0..<12).map { reading(24.5 + Double($0), 70 - 3 * Double($0), reset: 150) }
        let mixed = pace(own + other, reset: 168, now: 36)
        #expect(mixed.forecast == .tooEarly && mixed.latest?.at == at(36))
        // Conflicting values at one instant are dropped rather than averaged.
        let conflict = [reading(36, 50, reset: 168)]
        #expect(WeeklyQuotaEstimator.consistentReadings(own + conflict, now: at(36)).last?.at == at(35))
    }
}
