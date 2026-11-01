// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-24, AC-24.01, AC-24.02.
// Refs: US-15, AC-15.06; US-23, AC-23.03.
// Refs: US-02, AC-02.02, AC-02.03, AC-02.05; US-03, AC-03.01, AC-03.02, AC-03.03, AC-03.04, AC-03.09.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.12; US-15, AC-15.01, AC-15.02, AC-15.03, AC-15.04.
// Refs: US-23, AC-23.01, AC-23.02.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.06, AC-33.10; US-19, AC-19.03, AC-19.04, AC-19.05.
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
        let restorable = showingHistory ? restorableSelection(in: snapshots) : nil
        VStack(alignment: .leading, spacing: PanelStyle.Grid.group) {
            SessionListHeader(showingHistory: historyBinding,
                activeCount: available ? displayed.count : nil,
                historyCount: history.count,
                canClear: !displayed.isEmpty,
                clear: { model.clearDisplayedSessions(provider: provider) },
                restore: restorable.map { id in { restore(id) } })
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

    private func list(_ snapshots: [SessionSnapshot], labels: SessionIdentityLabels, history: Bool, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.observation.sessionID) { index, snapshot in
                if index > 0 {
                    // A hairline separates rows, except beside a selected row's highlight.
                    let quiet = model.selectedID == snapshot.observation.sessionID
                        || model.selectedID == snapshots[index - 1].observation.sessionID
                    Rectangle().fill(quiet ? Color.clear : PanelStyle.separator).frame(height: 0.5)
                        .padding(.leading, 36).padding(.trailing, PanelStyle.Space.medium)
                        .accessibilityHidden(true)
                }
                SessionRow(model: model, snapshot: snapshot, identity: labels.label(for: snapshot.observation.sessionID),
                           usage: usage[snapshot.provider], history: history, now: now,
                           restore: { restore(snapshot.observation.sessionID) })
            }
        }
        // The list fills the rest of the page, so a short list never leaves the page ending in blank glass.
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PanelModule(horizontal: PanelStyle.Layout.listInset, vertical: PanelStyle.Layout.listVerticalInset))
    }

    @ViewBuilder private func emptyState(history: Bool, available: Bool) -> some View {
        VStack(spacing: PanelStyle.Space.small) {
            if !history && !available {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Session monitoring unavailable").font(PanelStyle.Text.title).foregroundStyle(.secondary)
                Text("Refresh to try again").font(PanelStyle.Text.secondary).foregroundStyle(.tertiary)
            } else {
                Text(history ? "No local history" : "No visible conversations")
                    .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 3 * PanelStyle.Layout.rowHeight, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var unavailableNote: some View {
        Label("Session monitoring unavailable · Refresh to try again", systemImage: "exclamationmark.triangle")
            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
    }

    /// Restore stays explicit and applies only to the selected History row that can still be restored.
    private func restorableSelection(in snapshots: [SessionSnapshot]) -> UUID? {
        guard let selected = model.selected?.observation.sessionID,
              snapshots.contains(where: { $0.observation.sessionID == selected }),
              model.canRestore(sessionID: selected) else { return nil }
        return selected
    }
    private func restore(_ id: UUID) {
        guard model.canRestore(sessionID: id) else { return }
        model.restore(sessionID: id)
        historyBinding.wrappedValue = false
    }
}

/// One conversation: status symbol, title, metadata line and a right-aligned usage column.
/// The navigation column is always reserved, so usage never shifts between rows.
private struct SessionRow: View {
    @ObservedObject var model: SessionListModel
    let snapshot: SessionSnapshot
    let identity: String
    let usage: LocalUsageModel?
    let history: Bool
    let now: Date
    let restore: () -> Void

    var body: some View {
        let id = snapshot.observation.sessionID
        let notice = SessionNotice.prepare(snapshot)
        let canReturn = model.canRequestReturn(id)
        let status = SessionStatusStyle(snapshot)
        let title = snapshot.localPreview ?? (notice.titleIsPlaceholder ? "Session " + identity : notice.title)
        let selected = model.selectedID == id
        Button { model.select(id) } label: {
            HStack(spacing: PanelStyle.Space.module) {
                Image(systemName: status.symbol).font(.system(size: 15)).foregroundStyle(status.tone.color)
                    .frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                    Text(verbatim: title).font(PanelStyle.Text.primary).lineLimit(1).truncationMode(.tail)
                    metadata(status: status, canReturn: canReturn, project: notice.project)
                        .font(PanelStyle.Text.secondary).lineLimit(1).truncationMode(.tail)
                        .help(snapshot.observation.sessionID.uuidString)
                    if model.navigationUnavailableFor == id {
                        Label("Original terminal unavailable. Open it in its app.", systemImage: "info.circle")
                            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PanelStyle.Space.medium)
                if let usage {
                    SessionUsageColumn(usage: usage, sessionID: id, provider: snapshot.provider)
                } else {
                    UsageFigures(amount: nil, provider: snapshot.provider).help("Recorded session usage unavailable.")
                }
                Image(systemName: "arrow.up.forward.app").font(PanelStyle.Text.secondary).foregroundStyle(.tertiary)
                    .frame(width: 14).opacity(canReturn ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, PanelStyle.Layout.rowPadding)
            .frame(maxWidth: .infinity, minHeight: PanelStyle.Layout.rowHeight, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: PanelStyle.Radius.row, style: .continuous).fill(.tint.opacity(0.16))
                        .padding(.vertical, PanelStyle.Layout.rowHighlightInset)
                }
            }
            .contentShape(Rectangle())
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

    /// Project · agent · state · app · age, one line; only the attention state is colored.
    private func metadata(status: SessionStatusStyle, canReturn: Bool, project: String) -> Text {
        let dot = Text(verbatim: " · ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
        var line = Text(verbatim: project).fontWeight(.medium).foregroundColor(.secondary)
        if model.labelsAgents { line = line + dot + Text(verbatim: snapshot.provider.shortName).foregroundColor(.secondary) }
        line = line + dot + Text(status.label).foregroundColor(status.awaitsDeveloper ? status.tone.color : .secondary)
        if canReturn, let name = snapshot.navigationApplicationName {
            line = line + dot + Text(verbatim: name).foregroundColor(.secondary)
        }
        if let age = PanelStyle.relativeAge(since: snapshot.lastActivityAt, now: now) {
            line = line + dot + Text(verbatim: age).foregroundColor(.secondary)
        }
        return line
    }

    private func spokenSummary(status: SessionStatusStyle, title: String, project: String, canReturn: Bool) -> String {
        var parts = [title, project]
        if model.labelsAgents { parts.append(snapshot.provider.displayName) }
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

/// Observes only its provider's usage model, so one provider's refresh never re-renders another's rows.
private struct SessionUsageColumn: View {
    @ObservedObject var usage: LocalUsageModel
    let sessionID: UUID
    let provider: SessionProvider

    var body: some View {
        let amount = usage.snapshot?.sessions[sessionID]
        UsageFigures(amount: amount, provider: provider)
            .help(amount.map { LocalUsageText.costHelp($0, provider: provider)
                    + (ClaudeLimitsText.breakdown($0).map { "\nRecorded tokens: " + $0 } ?? "") }
                ?? "Recorded session usage unavailable." + (usage.unavailable ? " Refresh to try again." : ""))
    }
}

/// Every agent's rows show tokens over cost (a subscriber watches usage first); Claude's input,
/// output and cache categories are in the help text, so a total dominated by cache reads can be read apart (AC-33.10).
private struct UsageFigures: View {
    let amount: LocalUsageAmount?
    let provider: SessionProvider
    var body: some View {
        VStack(alignment: .trailing, spacing: PanelStyle.Space.hairline) {
            Text(LocalUsageText.tokens(amount)).font(PanelStyle.Text.primary)
            Text(LocalUsageText.cost(amount)).font(PanelStyle.Text.secondary)
                .foregroundStyle(amount?.estimatedUSD == nil ? .tertiary : .secondary)
        }
        .monospacedDigit().lineLimit(1)
        .frame(minWidth: 64, alignment: .trailing)
        .accessibilityHidden(true)
    }
}
