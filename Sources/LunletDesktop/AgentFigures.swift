// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.02, AC-04.03, AC-04.06, AC-04.08, AC-04.09, AC-04.12, AC-04.15, AC-04.17, AC-04.18; US-33, AC-33.10.
// Refs: US-24, AC-24.01, AC-24.02.
import Foundation
import LunletCore
import SwiftUI

/// One figure of an agent's figures row: what it is, its value and a few words about it (AC-04.17).
struct AgentFigure: Equatable, Identifiable {
    var label: String
    var value: String
    var note: String? = nil
    var id: String { label }
}

enum AgentFigures {
    static let unknown = "Unknown"

    /// Codex: the five-hour window when the account reports one (AC-04.15), Credits and reset entitlements
    /// (AC-04.06, AC-04.09), then today's recorded usage. Without a successful read the account figures say
    /// Unknown rather than an earlier value (AC-04.03).
    static func codex(snapshot: AccountLimitsSnapshot?, today: AgentFigure, now: Date) -> [AgentFigure] {
        var figures: [AgentFigure] = []
        if let snapshot {
            if let window = AccountUsagePresentation.fiveHour(in: snapshot) {
                let line = AccountUsagePresentation.windowLine(window, now: now)
                figures.append(.init(label: "5-hour window", value: line.left == "—" ? unknown : line.left,
                                     note: line.reset == "Reset —" ? nil : line.reset.prefix(1).lowercased() + line.reset.dropFirst()))
            }
        } else {
            figures.append(.init(label: "5-hour window", value: unknown))
        }
        figures.append(.init(label: "Credits", value: snapshot.flatMap(credits).flatMap(creditsValue) ?? unknown))
        let resets = snapshot?.earnedResets
        figures.append(.init(label: "Reset credits", value: resets?.availableCount.map(String.init) ?? unknown,
                             note: nextExpiry(resets, now: now)))
        return figures + [today]
    }

    /// Today's recorded tokens on this Mac with their API-price estimate on the same line, tokens first
    /// (AC-33.10); a missing price shows no cost, and a missing day is unknown, not zero.
    static func today(_ amount: LocalUsageAmount?, reading: Bool) -> AgentFigure {
        guard let amount, amount.tokens != nil else { return .init(label: "Today", value: reading ? "Reading…" : unknown) }
        return .init(label: "Today", value: LocalUsageText.tokens(amount),
                     note: amount.estimatedUSD == nil ? nil : LocalUsageText.cost(amount))
    }

    /// The Codex bucket's credits, or the only bucket's.
    static func credits(in snapshot: AccountLimitsSnapshot) -> AccountCredits? {
        if let codex = snapshot.buckets.first(where: { $0.id == "codex" }) { return codex.credits }
        return snapshot.buckets.count == 1 ? snapshot.buckets.first?.credits : nil
    }
    /// The reported balance; no currency is inferred.
    static func creditsValue(_ credits: AccountCredits) -> String? {
        if credits.unlimited == true { return "Unlimited" }
        if let balance = credits.balance { return AccountUsagePresentation.creditBalance(balance) }
        if credits.hasCredits == false { return "None" }
        return credits.hasCredits == true ? "Available" : nil
    }
    /// The soonest expiry among the available reset entitlements; every date is in the figure's help.
    static func nextExpiry(_ resets: EarnedResets?, now: Date) -> String? {
        guard let first = AccountUsagePresentation.resetExpiryLabels(resets, now: now).first else { return nil }
        return first == "—" ? "expiry unknown" : first == "Expired" ? "one expired" : "next expires in " + first
    }
}

/// The top of an agent's page, one module: the account line over the figures (AC-04.17). Text set straight on the
/// panel's glass takes the color of whatever window lies behind it, so the figures sit on a module as the sessions do.
struct AgentSummaryCard<Trailing: View>: View {
    let account: String
    let plan: String?
    /// The account line's explanation; it stays in help.
    var accountHelp: String = ""
    let figures: [AgentFigure]
    /// Longer explanations by figure label; they stay in help.
    var help: [String: String] = [:]
    let hoverPanel: UsageHoverPanelController
    /// What assistive tools call the figures.
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentAccountLine(account: account, plan: plan) { trailing }
                .padding(.horizontal, PanelStyle.Grid.margin)
                .padding(.top, PanelStyle.Layout.summaryEdge).padding(.bottom, PanelStyle.Layout.summaryGap)
                .help(accountHelp)
            AgentFiguresRow(figures: figures, help: help, hoverPanel: hoverPanel, label: label)
        }
        .modifier(PanelModule(padding: 0))
    }
}

/// The account line of an agent's page: who and which plan, then the age of the last successful read or the one
/// action the state calls for (AC-04.17).
struct AgentAccountLine<Trailing: View>: View {
    let account: String
    let plan: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            Text(verbatim: account).lineLimit(1).truncationMode(.middle)
            if let plan {
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(verbatim: plan).lineLimit(1).layoutPriority(1)
            }
            Spacer(minLength: PanelStyle.Grid.group)
            trailing.layoutPriority(1)
        }
        .font(PanelStyle.Text.secondary).foregroundStyle(.secondary).lineLimit(1)
        .frame(height: PanelStyle.Layout.secondaryLine)
    }
}

/// The figures of an agent's page under its account line: labels beside values in two columns, the second at the
/// trailing edge, or one line for a single figure. Resting the pointer on them, Return or Space on them, or Command-U
/// opens the floating chart; there is no chart button (AC-04.18). The row never asks for more than the width it is
/// offered: labels stay whole and a value too long for its column ends in an ellipsis, with the whole value in help.
struct AgentFiguresRow: View {
    let figures: [AgentFigure]
    /// Longer explanations by figure label; they stay in help.
    var help: [String: String] = [:]
    let hoverPanel: UsageHoverPanelController
    /// What assistive tools call the row.
    let label: String

    /// The row's height for a number of figures: its lines and gaps, under the hairline and above the card's edge.
    static func height(figures: Int) -> CGFloat {
        let lines = CGFloat(max(1, (figures + 1) / 2)), layout = PanelStyle.Layout.self
        return layout.summaryGap + lines * layout.secondaryLine + (lines - 1) * layout.summaryGap + layout.summaryEdge
    }

    var body: some View {
        Button(action: hoverPanel.showForKeyboard) {
            HStack(alignment: .top, spacing: 0) {
                column(0)
                Spacer(minLength: PanelStyle.Space.large)
                if figures.count > 1 { column(1) }
            }
            .font(PanelStyle.Text.secondary)
            .padding(.horizontal, PanelStyle.Grid.margin)
            .padding(.top, PanelStyle.Layout.summaryGap).padding(.bottom, PanelStyle.Layout.summaryEdge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { hairline }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("u", modifiers: .command)
        .background(UsageHoverAnchor(controller: hoverPanel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(figures.map { $0.label + " " + $0.value + ($0.note.map { ", " + $0 } ?? "") }.joined(separator: "; "))
        .accessibilityHint("Shows the usage chart (Command-U)")
    }

    /// Every second figure, from the first or from the second: a column of labels beside a column of values.
    private func column(_ first: Int) -> some View {
        let shown = stride(from: first, to: figures.count, by: 2).map { figures[$0] }
        return HStack(alignment: .top, spacing: PanelStyle.Space.small) {
            VStack(alignment: .leading, spacing: PanelStyle.Layout.summaryGap) {
                ForEach(shown) { figure in
                    Text(verbatim: figure.label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .frame(height: PanelStyle.Layout.secondaryLine).help(help[figure.label] ?? "")
                }
            }
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: PanelStyle.Layout.summaryGap) {
                ForEach(shown) { figure in
                    value(figure).lineLimit(1).truncationMode(.tail)
                        .frame(height: PanelStyle.Layout.secondaryLine).help(valueHelp(figure))
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(PanelStyle.separator).frame(height: 0.5).padding(.horizontal, PanelStyle.Grid.margin)
            .accessibilityHidden(true)
    }

    private func value(_ figure: AgentFigure) -> Text {
        let known = figure.value != AgentFigures.unknown
        let value = Text(verbatim: figure.value).fontWeight(.semibold).foregroundColor(known ? .primary : .secondary)
        guard let note = figure.note else { return value }
        return value + Text(verbatim: " · " + note).foregroundColor(.secondary)
    }
    /// The explanation, after the whole value when the column may have shortened it.
    private func valueHelp(_ figure: AgentFigure) -> String {
        let whole = figure.value + (figure.note.map { " · " + $0 } ?? "")
        return help[figure.label].map { whole + "\n" + $0 } ?? whole
    }
}
