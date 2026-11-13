// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.02; US-18, AC-18.02.
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.06, AC-04.08, AC-04.09, AC-04.12, AC-04.14, AC-04.15, AC-04.17, AC-04.18.
// Refs: US-24, AC-24.01, AC-24.02; US-03, AC-03.09.
import SwiftUI
import LunletCore

/// The top of the Codex page under the header, one card: the account line, then the figures with the five-hour
/// window, Credits, reset entitlements and today's recorded usage (AC-04.17). The account's own limit, weekly or longer, is in the header.
struct AccountUsageSummary: View {
    @ObservedObject var model: AccountUsageModel
    @ObservedObject var history: LocalUsageModel
    let hoverPanel: UsageHoverPanelController
    /// The panel's global Refresh, offered on the account line after a failed read (AC-04.12).
    var refresh: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        AgentSummaryCard(account: account, plan: plan, accountHelp: freshnessHelp,
                         figures: AgentFigures.codex(snapshot: snapshot, today: today, now: now), help: help,
                         hoverPanel: hoverPanel, label: "Codex usage") { freshness(now: now) }
    }

    private var snapshot: AccountLimitsSnapshot? { model.displayedSnapshot }
    private var account: String {
        snapshot?.identity?.email ?? (model.state == .loading ? "Reading account…" : "Codex account")
    }
    private var plan: String? { snapshot?.identity?.plan?.replacingOccurrences(of: "_", with: " ").capitalized }
    private var today: AgentFigure {
        AgentFigures.today(OverviewUsage.today(history.snapshot), reading: history.isLoading)
    }

    /// The age of the last successful read, or Refresh once a read has failed and nothing can be shown.
    @ViewBuilder private func freshness(now: Date) -> some View {
        if let snapshot {
            if let updated = AccountUsagePresentation.updatedLabel(at: snapshot.observedAt, now: now) {
                Text(updated).monospacedDigit().help("Last successful account update")
            }
        } else if model.state == .unavailable {
            Button("Refresh", action: refresh).buttonStyle(.plain).foregroundStyle(.tint)
                .help("The last account read failed; Refresh tries again.")
        }
    }

    private var help: [String: String] {
        ["5-hour window": "Codex's five-hour window, reported beside the account's longer limit. The header, the vine and the forecast show that longer limit.",
         "Credits": "Reported credit balance; no currency is inferred.",
         "Reset credits": resetHelp,
         "Today": "Recorded on this Mac from local Codex records. Cost is an estimate at published API list prices, not a bill."]
    }
    private var freshnessHelp: String {
        let source = "Codex account limits. Rest the pointer on the figures for \(history.historyDays)-day usage."
        guard let snapshot else {
            return source + (model.state == .unavailable ? " The last account read failed; Refresh can try again." : "")
        }
        return source + " Updated " + snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)
            + (AccountUsagePresentation.fiveHour(in: snapshot) == nil ? " Codex reports no five-hour window for this account." : "")
    }
    private var resetHelp: String {
        guard let resets = snapshot?.earnedResets else { return "Reset entitlements unavailable." }
        let dates = resets.details?.filter { $0.status == "available" }.map {
            $0.expiresAt.map { "Expires " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Expiration unknown"
        } ?? []
        return (["Available quota reset entitlements, separate from Credits."] + dates +
            (resets.detailCoverage == .complete ? [] : ["Some expiration details are unavailable."])).joined(separator: "\n")
    }
}
