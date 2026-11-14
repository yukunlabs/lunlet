// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.17; US-03, AC-03.09, AC-03.10; US-19, AC-19.09.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// The panel body has one width. Content that cannot shrink to it is laid out wider and centered, so both of its
/// edges are cut by the panel's outline and the header loses its margins.
@MainActor struct AgentPageLayoutTests {
    private static let size = CGSize(width: PanelPlacement.panelWidth, height: PanelStyle.Layout.panelHeight(notchHeight: 32))

    // Refs: US-04, AC-04.17.
    @Test func theFiguresRowStaysInsideThePageWithTheLongestValues() async throws {
        _ = NSApplication.shared
        let hover = UsageHoverPanelController(observesSystemEvents: false)
        defer { hover.shutdown() }
        let figures = [AgentFigure(label: "5-hour window", value: "100% left", note: "resets in 4h 59m"),
                       AgentFigure(label: "Credits", value: "1,234,567.89"),
                       AgentFigure(label: "Reset credits", value: "10", note: "next expires in 26d 13h"),
                       AgentFigure(label: "Today", value: "1,234M tokens", note: "≥$12,345")]
        // The card spans the page inside its margins and pads its own text.
        let offered = PanelPlacement.panelWidth - 2 * PanelStyle.Grid.margin
        for count in 1...figures.count {
            let row = AgentFiguresRow(figures: Array(figures.suffix(count)), hoverPanel: hover, label: "Synthetic usage")
            let laidOut = try await laidOutSize(of: row, offered: CGSize(width: offered, height: 80))
            #expect(laidOut.width <= offered + 0.5, "\(count) figures take \(laidOut.width) of \(offered)")
        }
    }

    // Refs: US-03, AC-03.09; US-04, AC-04.17; US-19, AC-19.09.
    @Test(arguments: [PanelFixture.Account.typical, .longFigures])
    func everyPageKeepsThePanelsWidth(account: PanelFixture.Account) async throws {
        _ = NSApplication.shared
        let fixture = try await PanelFixture(sessions: 3, account: account,
                                             titles: ["A conversation title long enough to need the whole row and then some more of it"])
        let band = NotchBand(height: 32, leading: (Self.size.width - 185) / 2, trailing: (Self.size.width - 185) / 2)
        let pages: [(String, SessionProvider?, Bool, PreferenceCategory?)] =
            [("overview", nil, false, nil), ("codex", .codex, false, nil), ("claude", .claude, false, nil), ("history", .codex, true, nil)]
            + PreferenceCategory.allCases.map { ("settings " + $0.rawValue, nil, false, $0) }
        for (name, tab, history, settings) in pages {
            let panel = fixture.panel(tab: tab, history: history, settings: settings).environment(\.notchBand, band)
            let laidOut = try await laidOutSize(of: panel, offered: Self.size)
            #expect(abs(laidOut.width - Self.size.width) <= 0.5, "\(name): \(laidOut.width) wide in \(Self.size.width)")
            #expect(abs(laidOut.height - Self.size.height) <= 0.5, "\(name): \(laidOut.height) tall in \(Self.size.height)")
        }
        await fixture.shutdown()
    }
}
