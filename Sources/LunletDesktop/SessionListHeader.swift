// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-23, AC-23.01, AC-23.02; US-15, AC-15.01, AC-15.03; US-24, AC-24.01, AC-24.02; US-19, AC-19.05.
import SwiftUI

/// Active/History switch in the panel's small segmented style, with one trailing action: Clear on Active,
/// Restore for the selected History row.
struct SessionListHeader: View {
    @Binding var showingHistory: Bool
    let activeCount: Int?
    let historyCount: Int
    let canClear: Bool
    let clear: () -> Void
    /// Restores the selected History conversation; nil when nothing selected can be restored.
    var restore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: PanelStyle.Space.medium) {
            PanelSegmentedControl(selection: $showingHistory, segments: [
                .init(value: false, title: "Active", detail: activeCount.map(String.init) ?? "—",
                      accessibilityLabel: "Active, " + (activeCount.map { "\($0) conversations" } ?? "unavailable")),
                .init(value: true, title: "History", detail: String(historyCount),
                      accessibilityLabel: "History, \(historyCount) conversations"),
            ], size: .small, label: "Conversations")
            Spacer(minLength: PanelStyle.Space.margin)
            if showingHistory, let restore {
                Button(action: restore) { Label("Restore to Active", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Return the selected conversation to Active. Observation continues.")
            } else if !showingHistory && canClear {
                Button("Clear", action: clear)
                    .buttonStyle(.borderless).controlSize(.small).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                    // Plain text ends on the cards' trailing text edge, as the segmented labels start on the leading one.
                    .padding(.trailing, PanelStyle.Grid.textInset)
                    .help("Move visible conversations to local history. Observation continues.")
            }
        }
        .frame(height: PanelStyle.Layout.listHeaderHeight)
        .accessibilityElement(children: .contain)
    }
}
