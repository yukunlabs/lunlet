// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-21, AC-21.04, AC-21.05; US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.15; US-33, AC-33.09.
import Foundation
import LunletClaude
import LunletCodex
import LunletCore
import Testing
@testable import LunletDesktop

struct MenuBarAllowanceTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(_ agent: String, _ span: AllowanceSpan, _ remaining: Double?,
                        resetIn: TimeInterval? = 33 * 3_600) -> MenuBarAllowanceText.Window {
        .init(agent: agent, span: span, remaining: remaining, resetsAt: resetIn.map { now.addingTimeInterval($0) })
    }

    @Test func offShowsNothingAndThePercentModesShowTheWindowClosestToRunningOut() {
        // AC-21.04: the lowest remaining among the shown windows, as the percent alone or with the reset countdown.
        let windows = [window("Codex", .week, 61), window("Claude Code", .week, 25)]
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .off, onlyBelow: nil, agents: 2, now: now) == nil)
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percent, onlyBelow: nil, agents: 2, now: now) == "Claude Code 25%")
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percentAndReset, onlyBelow: nil, agents: 2, now: now)
                == "Claude Code 25% · 1d 9h")
        // One selected agent needs no name.
        #expect(MenuBarAllowanceText.text(windows: [windows[0]], mode: .percent, onlyBelow: nil, agents: 1, now: now) == "61%")
    }

    @Test func theFiveHourWindowIsMarkedAndUnknownOrExpiredWindowsShowNoText() {
        // AC-21.04: "5h" marks a five-hour window; an unknown or past-reset window is skipped, and none leaves no text.
        let windows = [window("Codex", .week, 61), window("Codex", .fiveHour, 12, resetIn: 2 * 3_600)]
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percentAndReset, onlyBelow: nil, agents: 1, now: now) == "5h 12% · 2h")
        let unknown = [window("Codex", .week, nil), window("Claude Code", .week, 40, resetIn: -60)]
        #expect(MenuBarAllowanceText.text(windows: unknown, mode: .percent, onlyBelow: nil, agents: 2, now: now) == nil)
        // A window without a reset moment still shows its percent, without a placeholder countdown.
        let noReset = [window("Codex", .week, 44, resetIn: nil)]
        #expect(MenuBarAllowanceText.text(windows: noReset, mode: .percentAndReset, onlyBelow: nil, agents: 1, now: now) == "44%")
    }

    @Test func windowsComeFromEachSelectedAgentsOwnReadings() throws {
        // AC-21.04 draws on the windows the cards show: Codex weekly and five-hour (AC-04.07, AC-04.15), Claude weekly (AC-33.09).
        let snapshot = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"primary":{"usedPercent":88,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":39,"windowDurationMins":10080,"resetsAt":1800100000}}}
        """.utf8), observedAt: now)
        let claude = ClaudePlanLimits(sevenDay: .init(usedPercent: 75, resetsAt: now.addingTimeInterval(86_400), at: now), weekly: [])
        let windows = MenuBarAllowanceText.windows(providers: [.codex, .claude], codex: snapshot, claude: claude,
                                                   claudeConnected: true, now: now)
        #expect(windows == [.init(agent: "Codex", span: .week, remaining: 61, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)),
                            .init(agent: "Codex", span: .fiveHour, remaining: 12, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                            .init(agent: "Claude Code", span: .week, remaining: 25, resetsAt: now.addingTimeInterval(86_400))])
        // An unselected agent, a missing Codex read and a disconnected status line contribute nothing (AC-04.03).
        #expect(MenuBarAllowanceText.windows(providers: [.claude], codex: snapshot, claude: claude, claudeConnected: false, now: now).isEmpty)
        #expect(MenuBarAllowanceText.windows(providers: [.codex], codex: nil, claude: claude, claudeConnected: true, now: now).isEmpty)
    }

    // Refs: US-21, AC-21.04; US-04, AC-04.19. An account whose limit is a 30-day window shows that window, unmarked,
    // as a weekly one is; only the five-hour window carries a mark.
    @Test func aMonthlyCodexLimitIsShownLikeAWeeklyOne() throws {
        let epoch = Int(now.timeIntervalSince1970)
        let snapshot = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":43200,"resetsAt":\(epoch + 30 * 86_400 - 1)},"secondary":null,"planType":"free"}}
        """.utf8), observedAt: now)
        let windows = MenuBarAllowanceText.windows(providers: [.codex], codex: snapshot, claude: nil, claudeConnected: false, now: now)
        #expect(windows == [.init(agent: "Codex", span: AllowanceSpan(minutes: 43_200), remaining: 88,
                                  resetsAt: Date(timeIntervalSince1970: Double(epoch + 30 * 86_400 - 1)))])
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percentAndReset, onlyBelow: nil, agents: 1, now: now) == "88% · 29d 23h")
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percent, onlyBelow: nil, agents: 2, now: now) == "Codex 88%")
    }

    @Test func onlyBelowHidesTheTextWhileTheWindowIsAboveTheLevel() {
        // AC-21.05
        let windows = [window("Codex", .week, 35)]
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percent, onlyBelow: 30, agents: 1, now: now) == nil)
        #expect(MenuBarAllowanceText.text(windows: windows, mode: .percent, onlyBelow: 50, agents: 1, now: now) == "35%")
    }
}
