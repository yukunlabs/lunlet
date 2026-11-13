// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.04, AC-19.10; US-04, AC-04.01, AC-04.03, AC-04.16, AC-04.19.
import Foundation
import Testing
import LunletCodex
import LunletCore
@testable import LunletDesktop

@MainActor struct HeaderPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func label(_ remaining: Double?, reset: TimeInterval? = 4 * 86_400 + 2 * 3_600, unknown: HeaderPresentation.Unknown? = nil,
                       today: LocalUsageAmount? = nil) -> HeaderAgentLabel {
        HeaderAgentLabel(provider: .codex, remaining: remaining, plan: "Pro", resetsAt: reset.map { now.addingTimeInterval($0) },
                         unknown: remaining == nil ? unknown ?? .unknown : nil, today: today, waiting: 0)
    }

    // Refs: US-19, AC-19.10; US-04, AC-04.03.
    @Test func percentLeftIsWrittenAndAnUnknownLimitIsADashNeverZero() {
        #expect(label(62.4).percent == "62%" && label(62.4).lit == 0.624)
        #expect(label(0.4).percent == "<1%" && label(0).percent == "0%" && label(100).percent == "100%")
        #expect(label(nil).percent == "—" && label(nil).lit == nil)
        #expect(label(140).lit == 1 && label(-3).lit == 0)
    }

    // Refs: US-04, AC-04.01, AC-04.16; US-19, AC-19.10.
    @Test func theResetNamesItsWindowAndTheOverviewShortensItToTheCountdown() {
        let known = label(62)
        #expect(known.reset(now: now, moment: false) == "Week resets in 4d 2h")
        #expect(known.reset(now: now, moment: true) == "Week resets in 4d 2h · " + ClaudeLimitsText.moment(known.resetsAt!, now: now))
        // An elapsed reset reads due, without assuming the allowance has refreshed.
        #expect(label(62, reset: -60).reset(now: now, moment: true) == "Week reset due")
        #expect(label(62, reset: nil).reset(now: now, moment: true) == "Week reset —")
    }

    // Refs: US-04, AC-04.01, AC-04.16, AC-04.19; US-19, AC-19.10. A synthetic account reports plan free
    // with a single 30-day window and no weekly one; the header shows the limit the account has.
    @Test func aMonthlyCodexLimitIsShownAsItsOwnWindow() throws {
        let epoch = Int(now.timeIntervalSince1970)
        let snapshot = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":\(epoch + 30 * 86_400 - 1)},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"25000.0000000000"},"planType":"free"},"rateLimitResetCredits":{"availableCount":3,"credits":[]}}
        """.utf8), observedAt: now, accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"free"}}"#.utf8))
        let label = HeaderPresentation.codexLabel(snapshot: snapshot, state: .available(snapshot), today: nil, waiting: 0)
        #expect(label.percent == "100%" && label.lit == 1 && label.unknown == nil && label.plan == "Free" && label.window == "Month")
        #expect(label.reset(now: now, moment: false) == "Month resets in 29d 23h")
        #expect(label.reset(now: now, moment: true) == "Month resets in 29d 23h · " + ClaudeLimitsText.moment(label.resetsAt!, now: now))
        #expect(label.spoken(now: now).hasPrefix("100% left, Month resets in 29d 23h"))
        // A weekly account reads as it always did.
        let weekly = try AccountLimitsDecoder.decode(Data(#"{"rateLimits":{"secondary":{"usedPercent":38,"windowDurationMins":10080,"resetsAt":\#(epoch + 4 * 86_400 + 2 * 3_600)}}}"#.utf8), observedAt: now)
        let week = HeaderPresentation.codexLabel(snapshot: weekly, state: .available(weekly), today: nil, waiting: 2)
        #expect(week.percent == "62%" && week.window == "Week" && week.waiting == 2 && week.reset(now: now, moment: false) == "Week resets in 4d 2h")
        // Only the five-hour window, or no read at all: unknown, with the reason, never a borrowed window (AC-04.03).
        let short = try AccountLimitsDecoder.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#.utf8), observedAt: now)
        let none = HeaderPresentation.codexLabel(snapshot: short, state: .available(short), today: nil, waiting: 0)
        #expect(none.percent == "—" && none.unknown == .unknown && none.reset(now: now, moment: true) == "Unknown")
        #expect(HeaderPresentation.codexLabel(snapshot: nil, state: .loading, today: nil, waiting: 0).unknown == .reading)
        #expect(HeaderPresentation.codexLabel(snapshot: nil, state: .unavailable, today: nil, waiting: 0).unknown == .failed)
    }

    // Refs: US-19, AC-19.10; US-04, AC-04.03.
    @Test func anUnknownLimitSaysWhyInAWordOrTwo() {
        #expect(label(nil, unknown: .reading).reset(now: now, moment: true) == "Reading…")
        #expect(label(nil, unknown: .failed).reset(now: now, moment: false) == "Couldn't read")
        #expect(label(nil, unknown: .notConnected).reset(now: now, moment: false) == "Not connected")
        #expect(label(nil, unknown: .awaiting).reset(now: now, moment: false) == "No reading yet")
        #expect(label(nil, unknown: .unknown).reset(now: now, moment: false) == "Unknown")
    }

    // Refs: US-19, AC-19.10; US-04, AC-04.03.
    @Test func eachAgentsOwnStateDecidesWhyItsLimitIsUnknown() {
        typealias P = HeaderPresentation
        #expect(P.codexUnknown(state: .loading, hasLimit: false) == .reading)
        #expect(P.codexUnknown(state: .unavailable, hasLimit: false) == .failed)
        #expect(P.codexUnknown(state: .disabled, hasLimit: false) == .unknown)
        // A read that reports no window of a day or more stays unknown rather than borrowing the five-hour one.
        #expect(P.codexUnknown(state: .loading, hasLimit: true) == nil)
        #expect(P.claudeUnknown(connection: .notConnected, hasReading: false, readFailed: false) == .notConnected)
        #expect(P.claudeUnknown(connection: .checking, hasReading: false, readFailed: false) == .reading)
        #expect(P.claudeUnknown(connection: .connected, hasReading: false, readFailed: true) == .failed)
        #expect(P.claudeUnknown(connection: .connected, hasReading: false, readFailed: false) == .awaiting)
        #expect(P.claudeUnknown(connection: .changedOutsideLunlet, hasReading: true, readFailed: false) == .unknown)
        #expect(P.claudeUnknown(connection: .connected, hasReading: true, readFailed: true) == nil)
    }

    // Refs: US-19, AC-19.04, AC-19.10.
    @Test func todaysTokensAreWrittenPerAgentAndTheTotalIsALowerBound() {
        let codex = LocalUsageAmount(tokens: 96_000_000, estimatedUSD: 38.2, partial: false)
        let claude = LocalUsageAmount(tokens: 3_300_000, estimatedUSD: 4.1, partial: true)
        #expect(label(62, today: codex).todayTokens == "96M" && label(62, today: claude).todayTokens == "≥3.3M")
        #expect(label(62, today: nil).todayTokens == "—")
        let all = HeaderPresentation.totals([codex, claude])
        #expect(all.tokens == "≥99M" && all.cost == "≥$42")
        // Nothing recorded is unknown, not zero.
        #expect(HeaderPresentation.totals([nil, nil]) == HeaderTotals(tokens: "—", cost: nil))
        // One agent alone is its own exact figure, and a recorded zero is a zero.
        #expect(HeaderPresentation.totals([LocalUsageAmount(tokens: 0, estimatedUSD: 0, partial: false)]) == HeaderTotals(tokens: "0", cost: "≈$0.00"))
    }

    // Refs: US-04, AC-04.10, AC-04.16.
    @Test func theFigureWarnsBelowTwentyAndTenPercent() {
        #expect(label(62).warning == .none && label(20).warning == .none)
        #expect(label(19.9).warning == .low && label(10).warning == .low)
        #expect(label(9.9).warning == .critical && label(0).warning == .critical)
        #expect(label(nil).warning == .none)
    }

    // Refs: US-24, AC-24.02; US-19, AC-19.10.
    @Test func assistiveToolsHearThePercentTheResetAndTodaysUsage() {
        let spoken = label(62, today: LocalUsageAmount(tokens: 96_000_000, estimatedUSD: 38, partial: false)).spoken(now: now)
        #expect(spoken.contains("62% left") && spoken.contains("Week resets in 4d 2h") && spoken.contains("96M tokens today"))
        #expect(label(nil, unknown: .failed).spoken(now: now).hasPrefix("Couldn't read"))
    }
}
