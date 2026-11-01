// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.05; US-23, AC-23.01; US-24, AC-24.01, AC-24.02.
import AppKit
import SwiftUI
import Testing
@testable import LunletDesktop

/// The provider tabs and the Active/History switch share one segmented style that ignores the window's key state, so
/// the non-key hover preview and the key pinned panel look the same.
@MainActor struct PanelSegmentedControlTests {
    private func render(_ size: PanelSegmentedStyle.Size, selection: Int, scheme: ColorScheme,
                        state: ControlActiveState) throws -> Data {
        _ = NSApplication.shared
        let segments: [PanelSegmentedControl<Int>.Segment] = [
            .init(value: 0, title: "Overview"), .init(value: 1, title: "Codex"), .init(value: 2, title: "History", detail: "12"),
        ]
        let host = NSHostingView(rootView: PanelSegmentedControl(selection: .constant(selection), segments: segments,
                                                                 size: size, label: "Synthetic pages")
            .padding(8).environment(\.colorScheme, scheme).environment(\.controlActiveState, state))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }

    @Test func bothSizesDrawIdenticallyInKeyAndNonKeyWindows() throws {
        for size in [PanelSegmentedStyle.Size.regular, .small] {
            for scheme in [ColorScheme.light, .dark] {
                let pinned = try render(size, selection: 1, scheme: scheme, state: .key)
                #expect(try render(size, selection: 1, scheme: scheme, state: .inactive) == pinned)
                #expect(try render(size, selection: 1, scheme: scheme, state: .active) == pinned)
                // The render reflects its real inputs: moving the selection changes it.
                #expect(try render(size, selection: 0, scheme: scheme, state: .key) != pinned)
            }
        }
    }

    @Test func oneStyleWithElevatedNeutralSelectionAndFullHitTargets() {
        let regular = PanelSegmentedStyle(size: .regular, scheme: .light, contrast: .standard)
        let small = PanelSegmentedStyle(size: .small, scheme: .light, contrast: .standard)
        #expect(regular.height >= 28 && small.height >= 22)
        // Same treatment in both sizes: track, pill and shadow; only metrics and type differ.
        #expect(regular.track == small.track && regular.pill == small.pill && regular.shadow == small.shadow)
        #expect(regular.pill == .white && regular.pill != Color.accentColor && regular.border == nil)
        let dark = PanelSegmentedStyle(size: .regular, scheme: .dark, contrast: .standard)
        #expect(dark.pill != regular.pill && dark.track != regular.track)
        // Increase Contrast outlines the track and the pill.
        #expect(PanelSegmentedStyle(size: .small, scheme: .dark, contrast: .increased).border != nil)
    }

    @Test func arrowKeysMoveToTheAdjacentSegmentWithoutWrapping() {
        let values: [SessionProviderTab] = [.overview, .codex, .claude]
        #expect(PanelSegmentedControl<SessionProviderTab>.neighbor(of: .codex, offset: 1, in: values) == .claude)
        #expect(PanelSegmentedControl<SessionProviderTab>.neighbor(of: .codex, offset: -1, in: values) == .overview)
        #expect(PanelSegmentedControl<SessionProviderTab>.neighbor(of: .claude, offset: 1, in: values) == nil)
        #expect(PanelSegmentedControl<SessionProviderTab>.neighbor(of: .overview, offset: -1, in: values) == nil)
    }
    private enum SessionProviderTab: Hashable { case overview, codex, claude }
}
