// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.05; US-03, AC-03.09; US-33, AC-33.09, AC-33.10; US-04, AC-04.03; US-24, AC-24.01.
// Refs: US-35, AC-35.01, AC-35.03.
import AppKit
import SwiftUI
import Testing
import LunletClaude
import LunletCodex
import LunletCore
import LunletFeishu
import LunletMessaging
@testable import LunletDesktop

/// Opt-in offscreen renders of every panel page, light and dark, for owner review. Set `LUNLET_RENDER_DIR` to a
/// directory outside the repository; the real screen is never captured and glass is approximated by a flat fill.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"] != nil))
@MainActor struct PanelPageRenderTests {
    private static let notch = CGSize(width: 185, height: 32)

    @Test func renderEveryPageInLightAndDark() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ClaudeLimitsFixture(); defer { fixture.remove() }
        _ = try fixture.connection.connect()
        let t = Int(Date().timeIntervalSince1970)
        try fixture.write(state: "lunlet-claude-limits 1\nseven_day 15 \(t + 4 * 86_400) \(t - 300)\n",
                          log: "\(t - 2 * 86_400) 6 \(t + 4 * 86_400)\n\(t - 86_400) 11 \(t + 4 * 86_400)\n")
        let limits = ClaudePlanLimitsModel(service: fixture.connection)
        limits.setActive(true)
        try await ClaudeLimitsFixture.settle(limits) { limits.limits?.sevenDay != nil }

        for count in [1, 3] {
            let pages: [(String, SessionProvider?, Bool, PreferenceCategory?)] = count == 1
                ? [("overview", nil, false, nil), ("codex", .codex, false, nil), ("claude", .claude, false, nil)]
                : [("codex", .codex, false, nil), ("claude", .claude, false, nil), ("codex-history", .codex, true, nil)]
                    + PreferenceCategory.allCases.map { ("settings-" + $0.rawValue.lowercased(), nil, false, $0) }
            for (name, tab, history, settings) in pages {
                for dark in [true] {
                    try await render(sessions: count, tab: tab, history: history, settings: settings, limits: limits, dark: dark,
                                     to: directory.appendingPathComponent("\(name)-\(count)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        // A configured release build with a found update: the footer notice and About's update controls (AC-35.01,
        // AC-35.03). The driver is synthetic; nothing is fetched.
        let updater = AppUpdater(driver: SyntheticUpdateDriver())
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        for (name, tab, settings) in [("update-codex", SessionProvider.codex as SessionProvider?, nil as PreferenceCategory?),
                                      ("update-settings-about", nil, .about)] {
            for dark in [true] {
                try await render(sessions: 3, tab: tab, history: false, settings: settings, limits: limits, updater: updater,
                                 dark: dark, to: directory.appendingPathComponent("\(name)-3-\(dark ? "dark" : "light").png"))
            }
        }
        // A display without a notch, and the dog's bubble: the header has only its own top margin, and the actions
        // sit in its corner.
        for (name, tab) in [("overview-plain", nil as SessionProvider?), ("codex-plain", .codex)] {
            try await render(sessions: 3, tab: tab, history: false, settings: nil, limits: limits, notched: false, dark: true,
                             to: directory.appendingPathComponent("\(name)-3-dark.png"))
        }
        // More sessions than the list shows: three whole cards on each agent's page, the rest below the fold.
        for (name, tab) in [("codex-five", SessionProvider.codex), ("claude-five", .claude)] {
            try await render(sessions: 5, tab: tab, history: false, settings: nil, limits: limits, dark: true,
                             to: directory.appendingPathComponent("\(name)-5-dark.png"))
        }
        // Over a busy window, which the panel's glass lets through, and with the longest figures an account reports.
        for (name, tab) in [("overview-busy", nil as SessionProvider?), ("codex-busy", .codex), ("claude-busy", .claude)] {
            for dark in [true] {
                try await render(sessions: 2, tab: tab, history: false, settings: nil, limits: limits, account: .longFigures,
                                 busy: true, dark: dark, to: directory.appendingPathComponent("\(name)-2-\(dark ? "dark" : "light").png"))
            }
        }
        await limits.shutdown()
    }

    private func render(sessions count: Int, tab: SessionProvider?, history showHistory: Bool, settings: PreferenceCategory?,
                        limits: ClaudePlanLimitsModel, updater: AppUpdater? = nil, notched: Bool = true,
                        account: PanelFixture.Account = .typical, busy: Bool = false, dark: Bool, to url: URL) async throws {
        let fixture = try await PanelFixture(sessions: count, account: account)
        let panel = fixture.panel(tab: tab, history: showHistory, settings: settings)
        let (usage, codexUsage, claudeUsage) = (fixture.usage, fixture.codexUsage, fixture.claudeUsage)
        let width = PanelPlacement.panelWidth
        let height = PanelStyle.Layout.panelHeight(notchHeight: notched ? Self.notch.height : nil)
        let side = (width - Self.notch.width) / 2
        let band = notched ? NotchBand(height: Self.notch.height, leading: side, trailing: side) : nil
        let root = panel.environment(\.notchBand, band).environment(\.claudePlanLimits, limits).environment(\.appUpdater, updater)
            .frame(width: width, height: height)
            .background { if busy { BusyGlass(dark: dark) } else { RenderSurface() } }
            .overlay(alignment: .top) {
                // The hardware notch, drawn so the band layout can be judged.
                if notched {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black)
                        .frame(width: Self.notch.width, height: Self.notch.height)
                }
            }
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = .init(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        // Each provider page's hover overview: its weekly trend with the estimate above daily usage, in its own color.
        if count == 1, settings == nil, !showHistory, let tab {
            let overview = tab == .claude ? AnyView(UsageOverviewPanel(claudeLimits: limits, history: claudeUsage))
                : AnyView(UsageOverviewPanel(account: usage, history: codexUsage))
            let size = UsageHoverPanelController.overviewSize
            let view = overview.tint(AgentPalette.color(tab, accentHex: nil).color).frame(width: size.width, height: size.height)
                .background(RenderSurface()).environment(\.colorScheme, .dark)
            let chart = NSHostingView(rootView: view)
            chart.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            chart.frame = .init(origin: .zero, size: size)
            chart.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            chart.layoutSubtreeIfNeeded()
            if let bitmap = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) {
                chart.cacheDisplay(in: chart.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: url.deletingLastPathComponent().appendingPathComponent("hover-" + url.lastPathComponent))
            }
        }
        await fixture.shutdown()
    }
}

/// A stand-in for the panel's glass over a busy window: a dark terminal with bright rows under what on-device
/// captures showed of the system's dark glass (a fifth of the window behind over a mid gray, sRGB 80 over a dark
/// window to 133 over a white one). An offscreen render cannot draw the real material, and a flat fill hides how
/// much of the window behind reaches the page.
private struct BusyGlass: View {
    let dark: Bool
    var body: some View {
        VStack(spacing: 0) {
            Color(white: 0.11).frame(height: 190)
            Color(red: 0.05, green: 0.38, blue: 0.06).frame(height: 96)
            Color(white: 0.11).frame(height: 30)
            Color(red: 0.62, green: 0.56, blue: 0.1).frame(height: 14)
            Color(white: 0.11)
        }
        .overlay(Color(white: 0.39).opacity(0.8))
        .overlay(PanelStyle.surface.opacity(PanelStyle.surfaceDepth))
    }
}

/// The panel's surface as an offscreen render can draw it: its own color over a mid-gray stand-in for the glass, the
/// middle of what on-device captures showed.
struct RenderSurface: View {
    var body: some View { Color(white: 0.42).overlay(PanelStyle.surface.opacity(PanelStyle.surfaceDepth)) }
}
