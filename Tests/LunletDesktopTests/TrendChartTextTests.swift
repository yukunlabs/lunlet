// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.02, AC-32.03, AC-32.05, AC-32.06, AC-32.07, AC-32.08, AC-32.09.
// Refs: US-04, AC-04.02, AC-04.08; US-33, AC-33.04, AC-33.09, AC-33.10.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

/// The floating chart's words: its title, the comparison with the even pace, the one sentence that states the
/// forecast (AC-32.09) and the daily chart's footnote.
struct TrendChartTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var reading: QuotaReading { .init(at: now, remaining: 61.6, resetAt: now.addingTimeInterval(4 * 86_400)) }
    private func pace(_ forecast: QuotaPaceForecast, read: Bool = true, even: Double? = 58.3) -> QuotaPace {
        .init(forecast: forecast, latest: read ? reading : nil, evenPace: even)
    }
    // Refs: US-32, AC-32.01; US-04, AC-04.19. The title names the window the account has.
    @Test func theTitleNamesTheLimitsOwnWindow() {
        #expect(TrendChartText.title(.codex) == "Week limit · Codex" && TrendChartText.title(.claude) == "Week limit · Claude Code")
        #expect(TrendChartText.title(.codex, span: AllowanceSpan(minutes: 43_200)) == "Month limit · Codex")
        #expect(TrendChartText.title(.codex, span: AllowanceSpan(minutes: 20_160)) == "14-day limit · Codex")
    }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }

    @Test func theTitleNamesTheWindowAndTheAgentAndTheResetMoment() {
        // The same chart serves both agents (AC-33.09); each names its own window.
        #expect(TrendChartText.title(.codex) == "Week limit · Codex")
        #expect(TrendChartText.title(.claude) == "Week limit · Claude Code")
        let reset = now.addingTimeInterval(4 * 86_400)
        #expect(TrendChartText.resets(reset, now: now) == "resets " + ClaudeLimitsText.moment(reset, now: now))
    }

    @Test func theNowLineComparesRemainingWithTheEvenPaceAndIsNeverAForecast() {
        // AC-32.05: remaining against the even budget at the reading's time.
        #expect(TrendChartText.now(pace(.tooEarly), now: now) == "Now 62% left · even pace 58%")
        // AC-32.07: a reading more than an hour old states its time instead of "now".
        let later = now.addingTimeInterval(2 * 3600)
        #expect(TrendChartText.now(pace(.tooEarly), now: later)
            == "62% left at " + QuotaForecastText.time(now, now: later) + " · even pace 58%")
        // Omitted after a mid-window increase, and without a comparable reading.
        #expect(TrendChartText.now(pace(.tooEarly, even: nil), now: now) == nil)
        #expect(TrendChartText.now(pace(.tooEarly, read: false), now: now) == nil)
        #expect(TrendChartText.now(nil, now: now) == nil)
    }

    @Test func aForecastIsStatedOnceInWordsAsAnEstimate() {
        // AC-32.09: about how much is left at reset, with its range.
        let range = QuotaPaceEstimate(remainingAtReset: 0.4...27.2, central: 9.3, runOut: nil, earliestRunOut: nil,
                                      latestRunOut: nil, rough: false)
        #expect(TrendChartText.estimate(pace(.estimate(range)), stale: false, now: now)
            == "Estimate: about 9% left at reset (0–27%)")
        // AC-32.08: no decrease across a day gives one value, so no range is printed.
        let flat = QuotaPaceEstimate(remainingAtReset: 62...62, central: 62, runOut: nil, earliestRunOut: nil,
                                     latestRunOut: nil, rough: false)
        #expect(TrendChartText.estimate(pace(.estimate(flat)), stale: false, now: now) == "Estimate: about 62% left at reset")
    }

    @Test func aProjectedRunOutNamesItsTimeAndItsEarliestPlausibleTime() {
        // AC-32.02, AC-32.06: the run-out time, with the earliest plausible one; rough estimates keep their label.
        let runOut = now.addingTimeInterval(50 * 3600), earliest = now.addingTimeInterval(30 * 3600)
        let running = QuotaPaceEstimate(remainingAtReset: 0...10, central: 0, runOut: runOut, earliestRunOut: earliest,
                                        latestRunOut: nil, rough: false)
        #expect(TrendChartText.estimate(pace(.estimate(running)), stale: false, now: now)
            == "Estimate: may run out about \(day(runOut)) (earliest \(day(earliest)))")
        let rough = QuotaPaceEstimate(remainingAtReset: 0...10, central: 0, runOut: runOut, earliestRunOut: nil,
                                      latestRunOut: nil, rough: true)
        #expect(TrendChartText.estimate(pace(.estimate(rough)), stale: false, now: now)
            == "Rough estimate: may run out about \(day(runOut))")
        let roughRange = QuotaPaceEstimate(remainingAtReset: 15.4...34.6, central: 25, runOut: nil, earliestRunOut: nil,
                                           latestRunOut: nil, rough: true)
        #expect(TrendChartText.estimate(pace(.estimate(roughRange)), stale: false, now: now)
            == "Rough estimate: about 25% left at reset (15–35%)")
    }

    @Test func anEstimateFromAnOlderOrFailedReadingSaysSo() {
        // AC-32.07: more than an hour old states the reading's time; a failed read labels the estimate stale.
        let range = QuotaPaceEstimate(remainingAtReset: 15.4...34.6, central: 25, runOut: nil, earliestRunOut: nil,
                                      latestRunOut: nil, rough: false)
        let later = now.addingTimeInterval(2 * 3600)
        #expect(TrendChartText.estimate(pace(.estimate(range)), stale: false, now: later)
            == "Estimate: about 25% left at reset (15–35%) · as of " + QuotaForecastText.time(now, now: later))
        #expect(!TrendChartText.estimate(pace(.estimate(range)), stale: false, now: now.addingTimeInterval(3000)).contains("as of"))
        #expect(TrendChartText.estimate(pace(.estimate(range)), stale: true, now: now)
            == "Estimate: about 25% left at reset (15–35%) · stale, as of " + QuotaForecastText.time(now, now: now))
    }

    @Test func withoutAForecastTheLineGivesTheReasonInstead() {
        // AC-32.03, AC-32.07, AC-32.08: the reasons the chart already names, never an invented estimate.
        func line(_ value: QuotaPace?, at date: Date? = nil) -> String {
            TrendChartText.estimate(value, stale: false, now: date ?? now)
        }
        #expect(line(pace(.tooEarly)) == "Too early to estimate")
        #expect(line(pace(.exhausted(since: now))) == "Exhausted")
        #expect(line(pace(.unavailable(.staleReading)), at: now.addingTimeInterval(26 * 3600)) == "No reading since " + day(now))
        #expect(line(pace(.unavailable(.resetPassed), read: false, even: nil)) == "Reset due")
        #expect(line(pace(.unavailable(.unidentifiedWindow), read: false, even: nil)) == "Awaiting account reading")
        #expect(line(nil) == "Awaiting account reading")
        for value in [pace(.tooEarly), pace(.exhausted(since: now)), pace(.unavailable(.resetPassed))] {
            #expect(!line(value).contains("stimate:"))
        }
    }

    @Test func theDailyFootnoteKeepsItsSourceAndSaysWhenTotalsAreALowerBound() {
        // AC-04.02, AC-33.04: recorded on this Mac, estimates labeled; partial records are at least this much.
        #expect(TrendChartText.dailyFootnote(provider: .codex, cost: false, partial: false, partialPricing: false)
            == ["This Mac · local Codex records"])
        #expect(TrendChartText.dailyFootnote(provider: .codex, cost: true, partial: false, partialPricing: false)
            == ["This Mac · Estimated USD"])
        #expect(TrendChartText.dailyFootnote(provider: .codex, cost: false, partial: true, partialPricing: false)
            == ["Recorded on this Mac", "totals are at least this much"])
        #expect(TrendChartText.dailyFootnote(provider: .codex, cost: true, partial: true, partialPricing: true)
            == ["This Mac · Estimated USD", "totals are at least this much", "Partial pricing"])
        // Claude Code's recorded usage is always a lower bound.
        #expect(TrendChartText.dailyFootnote(provider: .claude, cost: false, partial: false, partialPricing: false)
            == ["Recorded on this Mac", "totals are at least this much"])
        #expect(TrendChartText.dailyFootnote(provider: .claude, cost: true, partial: false, partialPricing: false)
            == ["This Mac · API list-price estimate", "totals are at least this much"])
        // The partial-pricing note belongs to the cost metric only.
        #expect(TrendChartText.dailyFootnote(provider: .codex, cost: false, partial: false, partialPricing: true)
            == ["This Mac · local Codex records"])
    }
}
