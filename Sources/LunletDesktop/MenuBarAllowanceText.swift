// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-21, AC-21.04, AC-21.05; US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.15, AC-04.19; US-33, AC-33.09.
import Foundation
import LunletClaude
import LunletCore

/// The allowance text beside the lettering in menu-bar mode: display-only words that never route an action.
enum MenuBarAllowanceText {
    /// One window an agent reports, in the terms the panel shows it (AC-04.07, AC-04.15, AC-33.09).
    struct Window: Equatable, Sendable {
        let agent: String
        /// How long the window lasts; only the five-hour one is marked in the text.
        let span: AllowanceSpan
        let remaining: Double?
        let resetsAt: Date?
    }

    /// The window closest to running out among those known and not past their reset, as "25%" or "25% · 1d 9h",
    /// named when several agents are selected and marked "5h" for a five-hour window (AC-21.04); nil when the mode
    /// is off, no window is known, or the window is above the chosen level (AC-21.05).
    static func text(windows: [Window], mode: MenuBarAllowance, onlyBelow: Int?, agents: Int, now: Date) -> String? {
        guard mode != .off else { return nil }
        let known = windows.compactMap { window -> (window: Window, remaining: Double)? in
            guard let remaining = window.remaining else { return nil }
            if let reset = window.resetsAt, reset <= now { return nil }
            return (window, remaining)
        }
        guard let lowest = known.min(by: { $0.remaining < $1.remaining }) else { return nil }
        if let onlyBelow, lowest.remaining >= Double(onlyBelow) { return nil }
        var parts: [String] = []
        if agents > 1 { parts.append(lowest.window.agent) }
        if lowest.window.span == .fiveHour { parts.append("5h") }
        parts.append(percent(lowest.remaining))
        var text = parts.joined(separator: " ")
        if mode == .percentAndReset, let reset = lowest.window.resetsAt,
           let countdown = AccountUsagePresentation.countdown(until: reset, now: now) {
            text += " · " + countdown
        }
        return text
    }

    /// The windows each selected agent reports, in selection order, in the terms the panel shows them: Codex's own
    /// limit, weekly or as long as the account reports it, and its five-hour window (AC-04.07, AC-04.15), and Claude
    /// Code's connected, unexpired weekly reading (AC-33.09). A missing read or a disconnected status line contributes
    /// nothing rather than a zero (AC-04.03).
    static func windows(providers: [SessionProvider], codex: AccountLimitsSnapshot?, claude: ClaudePlanLimits?,
                        claudeConnected: Bool, now: Date) -> [Window] {
        providers.flatMap { provider -> [Window] in
            switch provider {
            case .codex:
                guard let codex else { return [] }
                return [AccountUsagePresentation.limit(in: codex), AccountUsagePresentation.fiveHour(in: codex)].compactMap { window in
                    window.map { Window(agent: "Codex", span: $0.span, remaining: $0.remainingPercent, resetsAt: $0.resetsAt) }
                }
            case .claude:
                guard claudeConnected, let week = ClaudeLimitsText.current(claude?.sevenDay, now: now) else { return [] }
                return [Window(agent: "Claude Code", span: .week, remaining: 100 - week.usedPercent, resetsAt: week.resetsAt)]
            }
        }
    }

    /// Whole percents; a nearly exhausted window reads "<1%", never 0%.
    private static func percent(_ remaining: Double) -> String {
        let clamped = min(100, max(0, remaining))
        return clamped > 0 && clamped < 1 ? "<1%" : String(Int(clamped)) + "%"
    }
}
