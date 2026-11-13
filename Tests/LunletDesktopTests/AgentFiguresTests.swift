// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.03, AC-04.06, AC-04.09, AC-04.12, AC-04.15, AC-04.17; US-33, AC-33.10.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

@MainActor struct AgentFiguresTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(fiveHour: Bool = true, credits: AccountCredits? = .init(balance: "75000", hasCredits: true, unlimited: false),
                          resets: EarnedResets? = nil) -> AccountLimitsSnapshot {
        let weekly = QuotaWindow(usedPercent: 38, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400))
        let short = QuotaWindow(usedPercent: 41, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3_600 + 60))
        return .init(buckets: [.init(id: "codex", name: "Codex", primary: fiveHour ? short : weekly, secondary: fiveHour ? weekly : nil,
                                     credits: credits)], earnedResets: resets, observedAt: now)
    }
    private let today = AgentFigure(label: "Today", value: "96M tokens", note: "≈$38")

    // Refs: US-04, AC-04.09, AC-04.15, AC-04.17.
    @Test func codexListsTheFiveHourWindowCreditsResetCreditsAndToday() {
        let resets = EarnedResets(availableCount: 2, details: [
            .init(id: "a", status: "available", resetType: nil, expiresAt: now.addingTimeInterval(3 * 86_400 + 3 * 3_600)),
            .init(id: "b", status: "available", resetType: nil, expiresAt: now.addingTimeInterval(6 * 86_400))])
        let figures = AgentFigures.codex(snapshot: snapshot(resets: resets), today: today, now: now)
        #expect(figures == [
            .init(label: "5-hour window", value: "59% left", note: "resets in 2h"),
            .init(label: "Credits", value: "75,000"),
            .init(label: "Reset credits", value: "2", note: "next expires in 3d 3h"),
            today])
    }

    // Refs: US-04, AC-04.15.
    @Test func anAccountWithoutAFiveHourWindowLeavesThatFigureOut() {
        let figures = AgentFigures.codex(snapshot: snapshot(fiveHour: false), today: today, now: now)
        #expect(figures.map(\.label) == ["Credits", "Reset credits", "Today"])
    }

    // Refs: US-04, AC-04.03, AC-04.12, AC-04.17.
    @Test func withoutASuccessfulReadEveryAccountFigureSaysUnknownAndTodayStays() {
        let figures = AgentFigures.codex(snapshot: nil, today: today, now: now)
        #expect(figures == [.init(label: "5-hour window", value: "Unknown"), .init(label: "Credits", value: "Unknown"),
                            .init(label: "Reset credits", value: "Unknown"), today])
    }

    // Refs: US-04, AC-04.06, AC-04.09.
    @Test func missingFieldsStayUnknownAndNoExpiryIsInvented() {
        let missing = AgentFigures.codex(snapshot: snapshot(credits: nil, resets: .init(availableCount: nil, details: nil)), today: today, now: now)
        #expect(missing[1] == .init(label: "Credits", value: "Unknown") && missing[2] == .init(label: "Reset credits", value: "Unknown"))
        let none = AgentFigures.codex(snapshot: snapshot(credits: .init(balance: nil, hasCredits: false, unlimited: false),
                                                         resets: .init(availableCount: 0, details: [])), today: today, now: now)
        #expect(none[1].value == "None" && none[2] == .init(label: "Reset credits", value: "0"))
        // A count whose expiry was not supplied says so rather than guessing a date.
        let undated = AgentFigures.codex(snapshot: snapshot(resets: .init(availableCount: 1, details: nil)), today: today, now: now)
        #expect(undated[2] == .init(label: "Reset credits", value: "1", note: "expiry unknown"))
        let unlimited = AgentFigures.codex(snapshot: snapshot(credits: .init(balance: nil, hasCredits: true, unlimited: true)), today: today, now: now)
        #expect(unlimited[1].value == "Unlimited")
    }

    // Refs: US-04, AC-04.02, AC-04.03, AC-04.17; US-33, AC-33.10.
    @Test func todayWritesTokensThenTheEstimateOnOneLine() {
        #expect(AgentFigures.today(.init(tokens: 96_000_000, estimatedUSD: 38.2, partial: false), reading: false)
                == .init(label: "Today", value: "96M tokens", note: "≈$38"))
        #expect(AgentFigures.today(.init(tokens: 3_300_000, estimatedUSD: 4.1, partial: true), reading: false)
                == .init(label: "Today", value: "≥3.3M tokens", note: "≥$4.10"))
        // Tokens without a known price show no invented cost.
        #expect(AgentFigures.today(.init(tokens: 1_000, estimatedUSD: nil, partial: false), reading: false)
                == .init(label: "Today", value: "1K tokens"))
        #expect(AgentFigures.today(nil, reading: true) == .init(label: "Today", value: "Reading…"))
        #expect(AgentFigures.today(nil, reading: false) == .init(label: "Today", value: "Unknown"))
    }
}
