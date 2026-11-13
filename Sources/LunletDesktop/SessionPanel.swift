// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-24, AC-24.01, AC-24.02.
// Refs: US-15, AC-15.06; US-23, AC-23.03.
// Refs: US-02, AC-02.02, AC-02.03, AC-02.05; US-03, AC-03.01, AC-03.02, AC-03.03, AC-03.04, AC-03.09.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.12; US-15, AC-15.01, AC-15.02, AC-15.03, AC-15.04.
// Refs: US-23, AC-23.01, AC-23.02.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.06, AC-33.10; US-19, AC-19.03, AC-19.04, AC-19.09.
import SwiftUI
import LunletCore

struct SessionPanel: View {
    @ObservedObject var model: SessionListModel
    /// Recorded usage per provider; each row reads its own provider's history.
    let usage: [SessionProvider: LocalUsageModel]
    /// One provider page, or every monitored provider when nil.
    var provider: SessionProvider? = nil
    /// Owned by the page when each provider tab keeps its own Active/History choice.
    private let externalHistory: Binding<Bool>?
    @ViewState private var localHistory = false

    init(model: SessionListModel, usage: [SessionProvider: LocalUsageModel], provider: SessionProvider? = nil,
         showingHistory: Binding<Bool>? = nil) {
        self.model = model; self.usage = usage; self.provider = provider; self.externalHistory = showingHistory
    }
    init(model: SessionListModel, usage: LocalUsageModel) { self.init(model: model, usage: [.codex: usage]) }

    private var historyBinding: Binding<Bool> { externalHistory ?? $localHistory }

    var body: some View {
        // Filter, order and disambiguate once per render rather than once per use or row.
        let showingHistory = historyBinding.wrappedValue
        let displayed = model.displayedSessions(for: provider)
        let history = model.history(for: provider)
        let available = provider.map(model.isMonitoringAvailable(for:)) ?? model.monitoringAvailable
        let snapshots = SessionOrdering().apply(to: showingHistory ? history : displayed, recentFirst: showingHistory)
        let labels = SessionIdentityLabels(ids: snapshots.map(\.observation.sessionID))
        VStack(alignment: .leading, spacing: PanelStyle.Grid.group) {
            SessionListHeader(title: provider.map { $0.displayName + " sessions" }, showingHistory: historyBinding,
                activeCount: available ? displayed.count : nil,
                historyCount: history.count,
                canClear: !displayed.isEmpty,
                clear: { model.clearDisplayedSessions(provider: provider) })
            if snapshots.isEmpty {
                emptyState(history: showingHistory, available: available)
            } else {
                if !available { unavailableNote }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    list(snapshots, labels: labels, history: showingHistory, now: context.date)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One card per conversation in a viewport of exactly three whole cards: no part of a fourth shows, further
    /// cards scroll, and what is above the list stays where it is.
    private func list(_ snapshots: [SessionSnapshot], labels: SessionIdentityLabels, history: Bool, now: Date) -> some View {
        GeometryReader { geometry in
            let card = PanelStyle.Layout.sessionCard(available: geometry.size.height)
            ScrollView {
                VStack(spacing: PanelStyle.Layout.rowGap) {
                    ForEach(snapshots, id: \.observation.sessionID) { snapshot in
                        SessionRow(model: model, snapshot: snapshot, identity: labels.label(for: snapshot.observation.sessionID),
                                   usage: usage[snapshot.provider], history: history, showsAgent: provider == nil && model.labelsAgents,
                                   now: now, height: card, restore: { restore(snapshot.observation.sessionID) })
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: PanelStyle.Layout.sessionViewport(available: geometry.size.height), alignment: .top)
        }
    }

    /// An empty place says why and what fills it.
    @ViewBuilder private func emptyState(history: Bool, available: Bool) -> some View {
        VStack(spacing: PanelStyle.Space.small) {
            if !history && !available {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Session monitoring unavailable").font(PanelStyle.Text.title).foregroundStyle(.secondary)
                Text("Refresh to try again").font(PanelStyle.Text.secondary).foregroundStyle(.tertiary)
            } else {
                Text(Self.emptyText(history: history, agent: provider?.displayName))
                    .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2 * PanelStyle.Grid.margin)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 2 * PanelStyle.Layout.rowHeight, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: PanelStyle.Radius.module, style: .continuous)
                .strokeBorder(PanelStyle.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
    static func emptyText(history: Bool, agent: String?) -> String {
        history ? "No history yet. Sessions you clear, and sessions that end, are kept here."
            : "No active " + (agent.map { $0 + " " } ?? "") + "sessions. Start one in any terminal and it appears here."
    }

    private var unavailableNote: some View {
        Label("Session monitoring unavailable · Refresh to try again", systemImage: "exclamationmark.triangle")
            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
    }

    private func restore(_ id: UUID) {
        guard model.canRestore(sessionID: id) else { return }
        model.restore(sessionID: id)
        historyBinding.wrappedValue = false
    }
}

/// One conversation as a card: its status symbol, the title over the project and app, then its state with the age
/// and recorded usage under it. A History card that is still running offers Restore (AC-15.03).
private struct SessionRow: View {
    @ObservedObject var model: SessionListModel
    let snapshot: SessionSnapshot
    let identity: String
    let usage: LocalUsageModel?
    let history: Bool
    /// The list mixes agents, so each card names its own.
    let showsAgent: Bool
    let now: Date
    /// The card's height, which the list sets so that three whole cards fill it.
    let height: CGFloat
    let restore: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let id = snapshot.observation.sessionID
        let notice = SessionNotice.prepare(snapshot)
        let canReturn = model.canRequestReturn(id)
        let status = SessionStatusStyle(snapshot)
        let title = snapshot.localPreview ?? (notice.titleIsPlaceholder ? "Session " + identity : notice.title)
        let selected = model.selectedID == id
        let shape = RoundedRectangle(cornerRadius: PanelStyle.Radius.module, style: .continuous)
        Button { model.select(id) } label: {
            HStack(spacing: PanelStyle.Space.module) {
                SessionStateBadge(status: status)
                VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                    Text(verbatim: title).font(PanelStyle.Text.primary.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    metadata(canReturn: canReturn, project: notice.project)
                        .font(PanelStyle.Text.secondary).lineLimit(1).truncationMode(.tail)
                        .help(snapshot.observation.sessionID.uuidString)
                    if model.navigationUnavailableFor == id {
                        Label("Original terminal unavailable. Open it in its app.", systemImage: "info.circle")
                            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PanelStyle.Space.medium)
                VStack(alignment: .trailing, spacing: PanelStyle.Space.tight) {
                    HStack(spacing: PanelStyle.Space.medium) {
                        if history && model.canRestore(sessionID: id) {
                            Button("Restore", action: restore).buttonStyle(.plain)
                                .font(PanelStyle.Text.secondary.weight(.semibold)).foregroundStyle(.tint)
                                .help("Return this conversation to Active. Observation continues.")
                        }
                        SessionStateLabel(status: status)
                    }
                    HStack(spacing: PanelStyle.Space.tight) {
                        if let usage {
                            SessionUsageColumn(usage: usage, sessionID: id, provider: snapshot.provider,
                                               age: PanelStyle.relativeAge(since: snapshot.lastActivityAt, now: now))
                        } else {
                            UsageFigures(amount: nil, age: PanelStyle.relativeAge(since: snapshot.lastActivityAt, now: now))
                                .help("Recorded session usage unavailable.")
                        }
                        if canReturn {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, PanelStyle.Grid.margin)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.16)) : status.awaitsDeveloper
                        ? AnyShapeStyle(PanelTone.attention.color.opacity(0.10)) : AnyShapeStyle(PanelStyle.moduleFill), in: shape)
            .overlay {
                if contrast == .increased || selected {
                    shape.strokeBorder(selected ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(PanelStyle.separator), lineWidth: 1)
                } else {
                    shape.strokeBorder(status.awaitsDeveloper ? AnyShapeStyle(PanelTone.attention.color.opacity(0.26)) : AnyShapeStyle(PanelStyle.moduleStroke), lineWidth: 0.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenSummary(status: status, title: title, project: notice.project, canReturn: canReturn))
        .accessibilityValue(spokenUsage)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            Task { await model.returnToSession(id) }
        }, including: canReturn ? .all : .none)
        .accessibilityActions {
            if canReturn {
                Button("Reveal original session") { Task { await model.returnToSession(id) } }
            }
            if history && model.canRestore(sessionID: id) {
                Button("Restore to Active", action: restore)
            }
        }
        .contextMenu {
            Button("Reveal original session") { Task { await model.returnToSession(id) } }.disabled(!canReturn)
        }
        .help(notice.summary + (canReturn ? "\n\nDouble-click to reveal this session in its original app."
                                          : "\n\nOriginal terminal location unavailable."))
    }

    /// Project · agent · app, one line; the state has its own pill and the age sits with the usage.
    private func metadata(canReturn: Bool, project: String) -> Text {
        let dot = Text(verbatim: " · ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
        var line = Text(verbatim: project).fontWeight(.medium).foregroundColor(.secondary)
        // An agent's own page names the agent once, above the list.
        if showsAgent { line = line + dot + Text(verbatim: snapshot.provider.shortName).foregroundColor(.secondary) }
        if canReturn, let name = snapshot.navigationApplicationName {
            line = line + dot + Text(verbatim: name).foregroundColor(.secondary)
        }
        return line
    }

    private func spokenSummary(status: SessionStatusStyle, title: String, project: String, canReturn: Bool) -> String {
        var parts = [title, project]
        if showsAgent { parts.append(snapshot.provider.displayName) }
        parts.append(status.label)
        if canReturn, let name = snapshot.navigationApplicationName { parts.append(name) }
        if let age = PanelStyle.spokenAge(since: snapshot.lastActivityAt, now: now) { parts.append(age) }
        return parts.joined(separator: ", ")
    }
    private var spokenUsage: String {
        let amount = usage?.snapshot?.sessions[snapshot.observation.sessionID]
        if snapshot.provider == .claude, let categories = ClaudeLimitsText.spokenBreakdown(amount) {
            return LocalUsageText.cost(amount) + ", " + categories
        }
        return LocalUsageText.tokens(amount) + ", " + LocalUsageText.cost(amount)
    }
}

/// A session card's state as one round badge: the same size and shape for every state, its glyph on a wash of its
/// tone. Color is kept for the badge; the words beside it stay quiet (AC-24.02: the glyph and the words carry the
/// state, never the color alone).
private struct SessionStateBadge: View {
    let status: SessionStatusStyle
    var body: some View {
        let quiet = status.tone == .neutral || status.tone == .muted
        Image(systemName: status.glyph).font(.system(size: 10, weight: .bold))
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(status.tone.color))
            .frame(width: 24, height: 24)
            .background(quiet ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(status.tone.color.opacity(0.18)), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The state in words, at the card's trailing edge: plain and quiet, in the attention color only while the session
/// waits for the developer.
private struct SessionStateLabel: View {
    let status: SessionStatusStyle
    var body: some View {
        Text(status.label).font(PanelStyle.Text.secondary.weight(.medium)).lineLimit(1)
            .foregroundStyle(status.awaitsDeveloper ? AnyShapeStyle(status.tone.color) : AnyShapeStyle(.secondary))
            .frame(height: 18)
            .accessibilityHidden(true)
    }
}

/// Observes only its provider's usage model, so one provider's refresh never re-renders another's rows.
private struct SessionUsageColumn: View {
    @ObservedObject var usage: LocalUsageModel
    let sessionID: UUID
    let provider: SessionProvider
    let age: String?

    var body: some View {
        let amount = usage.snapshot?.sessions[sessionID]
        UsageFigures(amount: amount, age: age)
            .help(amount.map { LocalUsageText.costHelp($0, provider: provider)
                    + (ClaudeLimitsText.breakdown($0).map { "\nRecorded tokens: " + $0 } ?? "") }
                ?? "Recorded session usage unavailable." + (usage.unavailable ? " Refresh to try again." : ""))
    }
}

/// Age, tokens and the API-price estimate on one small line, tokens before cost (AC-33.10); Claude's input, output
/// and cache categories are in the help text, so a total dominated by cache reads can be read apart.
private struct UsageFigures: View {
    let amount: LocalUsageAmount?
    let age: String?
    var body: some View {
        Text(verbatim: Self.line(amount, age: age))
            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
            .monospacedDigit().lineLimit(1)
            .accessibilityHidden(true)
    }
    /// "2m · 2.4M · ≈$3.10"; an unknown part is left out rather than shown as zero, and nothing known reads a dash.
    static func line(_ amount: LocalUsageAmount?, age: String?) -> String {
        var parts = age.map { [$0] } ?? []
        if let tokens = amount?.tokens {
            parts.append((amount?.partial == true ? "≥" : "") + tokens.formatted(.number.notation(.compactName)))
        }
        if amount?.estimatedUSD != nil { parts.append(LocalUsageText.cost(amount)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
