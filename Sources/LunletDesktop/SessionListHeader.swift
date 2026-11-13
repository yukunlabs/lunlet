// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-23, AC-23.01, AC-23.02; US-15, AC-15.01, AC-15.03, AC-15.06; US-24, AC-24.01, AC-24.02; US-19, AC-19.09.
import SwiftUI

/// The list header of an agent's page: the agent's sessions named, the Active/History switch in the panel's small
/// segmented style and, on Active only, Clear.
struct SessionListHeader: View {
    /// The agent whose sessions the list shows, named before the switch on an agent's page.
    var title: String? = nil
    @Binding var showingHistory: Bool
    let activeCount: Int?
    let historyCount: Int
    let canClear: Bool
    let clear: () -> Void

    var body: some View {
        HStack(spacing: PanelStyle.Space.medium) {
            if let title {
                Text(verbatim: title).font(PanelStyle.Text.title).lineLimit(1).accessibilityAddTraits(.isHeader)
                    .padding(.leading, PanelStyle.Space.tight)
            }
            PanelSegmentedControl(selection: $showingHistory, segments: [
                .init(value: false, title: "Active", detail: activeCount.map(String.init) ?? "—",
                      accessibilityLabel: "Active, " + (activeCount.map { "\($0) conversations" } ?? "unavailable")),
                .init(value: true, title: "History", detail: String(historyCount),
                      accessibilityLabel: "History, \(historyCount) conversations"),
            ], size: .small, label: "Conversations")
            .fixedSize()
            Spacer(minLength: PanelStyle.Space.margin)
            // History has no clear action of its own (AC-15.06); a History row that can return offers Restore itself.
            if !showingHistory && canClear {
                Button("Clear", action: clear)
                    .buttonStyle(.plain).font(PanelStyle.Text.secondary.weight(.semibold)).foregroundStyle(.tint)
                    .padding(.trailing, PanelStyle.Space.tight)
                    .help("Move visible conversations to local history. Nothing is deleted or stopped; observation continues.")
            }
        }
        .frame(height: PanelStyle.Layout.listHeaderHeight)
        .accessibilityElement(children: .contain)
    }
}
