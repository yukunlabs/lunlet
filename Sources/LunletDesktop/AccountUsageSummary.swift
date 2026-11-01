// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.02; US-18, AC-18.02.
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.06, AC-04.07, AC-04.08, AC-04.09, AC-04.10, AC-04.12.
// Refs: US-24, AC-24.01, AC-24.02; US-03, AC-03.09.
import SwiftUI
import LunletCore

struct AccountUsageSummary: View {
    @ObservedObject var model: AccountUsageModel
    let hoverPanel: UsageHoverPanelController

    var historyDays: Int = 5
    var accentHex: String? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    /// The same rhythm as the Claude card: a title line, an account line, the limits group (the remaining figure,
    /// the meter and the reset line) and a footnote. One size per line; color and weight set items apart.
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PanelStyle.Space.small) {
                Text("Limits").font(PanelStyle.Text.title).accessibilityAddTraits(.isHeader)
                UsageChartButton(label: "Show usage history", action: hoverPanel.showForKeyboard)
                Spacer(minLength: PanelStyle.Grid.row)
            }
            .frame(height: PanelStyle.Layout.line)
            HStack(spacing: PanelStyle.Space.tight) {
                Image(systemName: "person.crop.circle").accessibilityHidden(true)
                Text(snapshot?.identity?.email ?? "Codex account").lineLimit(1).truncationMode(.middle)
                    .help(snapshot?.identity?.email ?? "Account identity unavailable")
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(snapshot?.identity?.plan?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Plan —").lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: PanelStyle.Grid.group)
                if let snapshot, let updated = AccountUsagePresentation.updatedLabel(at: snapshot.observedAt, now: now) {
                    Text(updated).lineLimit(1).layoutPriority(1).help("Last successful account update")
                }
            }
            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
            .frame(height: PanelStyle.Layout.secondaryLine)
            .padding(.top, PanelStyle.Grid.row)
            VStack(alignment: .leading, spacing: PanelStyle.Grid.row) {
                HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.tight) {
                    if let remaining = weekly?.remainingPercent {
                        Text(remaining.formatted(.number.precision(.fractionLength(0...1))) + "%")
                        Text("left").fontWeight(.regular).foregroundStyle(.secondary)
                    } else {
                        Text(model.state == .loading ? "Refreshing…" : "Unavailable").fontWeight(.regular).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(PanelStyle.Text.figure)
                .frame(height: PanelStyle.Layout.line)
                AllowanceBar(remaining: weekly?.remainingPercent, accentHex: accentHex)
                HStack {
                    if let reset = weekly?.resetsAt {
                        if let remaining = AccountUsagePresentation.countdown(until: reset, now: now) {
                            Text("Resets in " + remaining)
                        } else { Text("Reset due") }
                        Spacer(minLength: PanelStyle.Space.tight)
                        Text(reset, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    } else {
                        Text("Reset —")
                        Spacer(minLength: PanelStyle.Space.tight)
                        if model.state == .unavailable { Text("Refresh to try again").foregroundStyle(.tertiary) }
                    }
                }
                .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                .frame(height: PanelStyle.Layout.secondaryLine)
            }
            .padding(.top, PanelStyle.Grid.group)
            .contentShape(Rectangle())
            .background(UsageHoverAnchor(controller: hoverPanel))
            .help(freshnessHelp)
            HStack(spacing: PanelStyle.Space.tight) {
                Text("Credits").foregroundStyle(.secondary)
                Text(creditsLabel)
                    .help("Reported credit balance; no currency is inferred.")
                Spacer(minLength: PanelStyle.Space.medium)
                let expiry = AccountUsagePresentation.resetExpiryLabels(snapshot?.earnedResets, now: now)
                HStack(spacing: PanelStyle.Space.tight) {
                    Text("Reset credits").foregroundStyle(.secondary)
                    Text(snapshot?.earnedResets?.availableCount.map(String.init) ?? "—")
                    if !expiry.isEmpty {
                        Image(systemName: "clock").imageScale(.small).foregroundStyle(.secondary).padding(.leading, 2)
                        Text(expiry.joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                }.help(resetHelp)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Limit reset credits")
            }
            .font(PanelStyle.Text.secondary).lineLimit(1)
            .frame(height: PanelStyle.Layout.secondaryLine)
            .padding(.top, PanelStyle.Grid.group)
        }
        .modifier(PanelModule())
    }

    private var snapshot: AccountLimitsSnapshot? {
        model.displayedSnapshot
    }
    private var weekly: WeeklyAllowance? { snapshot.flatMap(AccountUsagePresentation.weekly) }
    private var credits: AccountCredits? {
        guard let buckets = snapshot?.buckets else { return nil }
        if let codex = buckets.first(where: { $0.id == "codex" }) { return codex.credits }
        return buckets.count == 1 ? buckets.first?.credits : nil
    }
    private var creditsLabel: String {
        guard let credits else { return "—" }
        if credits.unlimited == true { return "Unlimited" }
        if let balance = credits.balance { return AccountUsagePresentation.creditBalance(balance) }
        if credits.hasCredits == false { return "None" }
        return credits.hasCredits == true ? "Available" : "—"
    }
    private var freshnessHelp: String {
        let source = "Codex account limits. Hover for \(historyDays)-day usage."
        guard let snapshot else {
            return source + (model.state == .unavailable ? " The last account read failed; Refresh can try again." : "")
        }
        return source + " Updated " + snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)
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

/// Opens the usage chart from the keyboard (Command-U) as well as by hovering its anchor.
struct UsageChartButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(PanelIconButtonStyle(size: PanelStyle.Layout.inlineButton))
        .accessibilityLabel(label)
        .help("Show usage history (⌘U)").keyboardShortcut("u", modifiers: .command)
    }
}
