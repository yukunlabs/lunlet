// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.04, AC-19.10; US-04, AC-04.01, AC-04.03, AC-04.10, AC-04.16, AC-04.19; US-24, AC-24.02.
import Foundation
import LunletCore

/// What one agent's body says in the header: percent left of its limit window, its plan, the reset and today's
/// recorded tokens, or why the limit is unknown (AC-19.10).
struct HeaderAgentLabel: Equatable {
    enum Warning: Equatable { case none, low, critical }
    var provider: SessionProvider
    /// Percent left of the limit window; nil while it is unknown, never zero for a missing value (AC-04.03).
    var remaining: Double?
    var plan: String?
    var resetsAt: Date?
    var unknown: HeaderPresentation.Unknown?
    var today: LocalUsageAmount?
    /// Sessions waiting for the developer, which the body's badge counts (AC-19.11).
    var waiting: Int
    /// The window's own word, which starts the reset line: "Week", or "Month" for an account whose limit is monthly.
    var window = AllowanceSpan.week.name

    /// "62%", "<1%" for a nearly spent window, a dash while unknown.
    var percent: String {
        guard let remaining else { return "—" }
        return (remaining > 0 && remaining < 1 ? "<1" : String(Int(min(100, max(0, remaining))))) + "%"
    }
    /// The share of the body's disc that is lit.
    var lit: Double? { remaining.map { min(1, max(0, $0 / 100)) } }
    /// Today's recorded tokens on this Mac, a lower bound when the records are partial.
    var todayTokens: String {
        guard let tokens = today?.tokens else { return "—" }
        return (today?.partial == true ? "≥" : "") + tokens.formatted(.number.notation(.compactName))
    }
    /// The warning steps of the allowance palette (AC-04.10): toward yellow below 20%, toward red below 10%.
    var warning: Warning {
        guard let remaining else { return .none }
        return remaining < 10 ? .critical : remaining < 20 ? .low : .none
    }
    /// The window and its reset in the shared wording (AC-04.01); the Overview leaves the weekday and time out. While
    /// the limit is unknown the line says why instead.
    func reset(now: Date, moment: Bool) -> String {
        if let unknown { return unknown.text }
        guard let resetsAt else { return window + " reset —" }
        guard let countdown = AccountUsagePresentation.countdown(until: resetsAt, now: now) else { return window + " reset due" }
        return window + " resets in " + countdown + (moment ? " · " + ClaudeLimitsText.moment(resetsAt, now: now) : "")
    }
    func spoken(now: Date) -> String {
        let limit = unknown.map(\.text) ?? percent + " left, " + reset(now: now, moment: true)
        return limit + ", " + (today?.tokens == nil ? "today's usage unknown" : todayTokens + " tokens today")
            + (waiting > 0 ? ", \(waiting) waiting for you" : "")
    }
}

struct HeaderTotals: Equatable {
    var tokens: String
    var cost: String?
}

enum HeaderPresentation {
    /// Why a limit is unknown, in the word or two the header shows (AC-19.10).
    enum Unknown: Equatable {
        case reading, failed, notConnected, awaiting, unknown
        var text: String {
            switch self {
            case .reading: "Reading…"
            case .failed: "Couldn't read"
            case .notConnected: "Not connected"
            case .awaiting: "No reading yet"
            case .unknown: "Unknown"
            }
        }
    }

    /// Codex's body: its account's own limit window (AC-04.07), named by its length, or why there is none. Nothing is
    /// borrowed from the five-hour window or from an earlier read (AC-04.03, AC-19.10).
    static func codexLabel(snapshot: AccountLimitsSnapshot?, state: AccountUsageModel.State, today: LocalUsageAmount?,
                           waiting: Int) -> HeaderAgentLabel {
        let limit = snapshot.flatMap(AccountUsagePresentation.limit)
        let remaining = limit?.remainingPercent
        return HeaderAgentLabel(provider: .codex, remaining: remaining,
                                plan: snapshot?.identity?.plan?.replacingOccurrences(of: "_", with: " ").capitalized,
                                resetsAt: limit?.resetsAt,
                                unknown: remaining == nil ? codexUnknown(state: state, hasLimit: false) ?? .unknown : nil,
                                today: today, waiting: waiting, window: (limit?.span ?? .week).name)
    }

    /// Codex: a read under way, a failed read, or a read that reports no limit window of a day or more.
    static func codexUnknown(state: AccountUsageModel.State, hasLimit: Bool) -> Unknown? {
        if hasLimit { return nil }
        switch state {
        case .loading: return .reading
        case .unavailable: return .failed
        case .disabled, .stopping, .available: return .unknown
        }
    }

    /// Claude Code: its status line's connection first, then whether a reading has arrived (AC-33.08, AC-33.09).
    static func claudeUnknown(connection: ClaudePlanLimitsModel.Connection, hasReading: Bool, readFailed: Bool) -> Unknown? {
        switch connection {
        case .notConnected: return .notConnected
        case .checking: return .reading
        case .changedOutsideLunlet, .unavailable: return .unknown
        case .connected: return hasReading ? nil : readFailed ? .failed : .awaiting
        }
    }

    /// Today's recorded tokens across the selected agents and their estimated cost, a lower bound as the Overview's
    /// totals are (AC-19.07). Allowances are never combined (AC-19.04).
    static func totals(_ today: [LocalUsageAmount?]) -> HeaderTotals {
        let sum = today.count == 1 ? today[0] : OverviewUsage.combined(today)
        guard let sum, let tokens = sum.tokens else { return .init(tokens: "—", cost: nil) }
        return .init(tokens: (sum.partial ? "≥" : "") + tokens.formatted(.number.notation(.compactName)),
                     cost: sum.estimatedUSD == nil ? nil : LocalUsageText.cost(sum))
    }
}
