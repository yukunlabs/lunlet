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

// Synthetic models for the real panel content: no account read, Keychain, network or session source. Shared with the
// product film render.
actor RenderEnrollmentStore: EnrollmentStoring {
    func save(_ enrollment: FeishuEnrollment) {}
    func load() -> FeishuEnrollment? { nil }
    func remove() {}
}
actor RenderCredentialStore: ChannelCredentialStoring {
    func load() -> Data? { nil }
    func authorize() -> Data? { nil }
    func save(_ data: Data) {}
    func remove() {}
}
struct RenderAccount: CodexAccountReading {
    let snapshot: AccountLimitsSnapshot
    func readLimits() async throws -> AccountLimitsSnapshot { snapshot }
}
struct RenderUsage: LocalUsageReading {
    let history: LocalUsageHistory
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory { history }
}
final class RenderPower: IdleSleepControlling { func setEnabled(_ enabled: Bool) {} }
@MainActor final class RenderCues: TaskCuePresenting { func show(_ cues: [TaskCue]) {}; func hide() {} }

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
        try fixture.write(state: "lunlet-claude-limits 1\nfive_hour 5 \(t + 5_400) \(t - 300)\nseven_day 15 \(t + 4 * 86_400) \(t - 300)\n",
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
                for dark in [false, true] {
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
            for dark in [false, true] {
                try await render(sessions: 3, tab: tab, history: false, settings: settings, limits: limits, updater: updater,
                                 dark: dark, to: directory.appendingPathComponent("\(name)-3-\(dark ? "dark" : "light").png"))
            }
        }
        await limits.shutdown()
    }

    private func render(sessions count: Int, tab: SessionProvider?, history showHistory: Bool, settings: PreferenceCategory?,
                        limits: ClaudePlanLimitsModel, updater: AppUpdater? = nil, dark: Bool, to url: URL) async throws {
        let suite = "com.lunlet.test.render.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let skinDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-render-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: skinDirectory) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.providers = [.codex, .claude] }

        let now = Date(), epoch = Int(now.timeIntervalSince1970)
        let account = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"secondary":{"usedPercent":38,"windowDurationMins":10080,"resetsAt":\(epoch + 4*86400 + 3*3600)},"credits":{"balance":"75000.000000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 3*86400 + 4*3600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 11*86400 + 8*3600)}]}}
        """.utf8), observedAt: now.addingTimeInterval(-120),
            accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8))
        let usage = AccountUsageModel(client: RenderAccount(snapshot: account))
        usage.start()

        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        let ids = (0..<count).map { _ in UUID() }, claudeIDs = (0..<count).map { _ in UUID() }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: today)! }
        let codexAmounts: [Double] = [140, 95, 210, 60, 107]
        let codexHistory = LocalUsageHistory(days: codexAmounts.enumerated().map { index, cost in
            .init(date: day(4 - index), amount: .init(tokens: Int64(cost * 900_000), estimatedUSD: cost, partial: false))
        }, sessions: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, LocalUsageAmount(tokens: 2_400_000, estimatedUSD: 3.1, partial: false))
        }), partial: false)
        let breakdown = LocalTokenBreakdown(input: 1_200, output: 45_000, cacheWrite: 120_000, cacheRead: 3_400_000)
        let claudeAmounts: [Double] = [30, 55, 18, 72, 41]
        let claudeHistory = LocalUsageHistory(days: claudeAmounts.enumerated().map { index, cost in
            .init(date: day(4 - index),
                  amount: .init(tokens: Int64(cost * 80_000), estimatedUSD: cost, partial: true, breakdown: breakdown))
        }, sessions: Dictionary(uniqueKeysWithValues: claudeIDs.map {
            ($0, LocalUsageAmount(tokens: 3_566_200, estimatedUSD: 4.12, partial: true, breakdown: breakdown))
        }), partial: true)
        let codexUsage = LocalUsageModel(reader: RenderUsage(history: codexHistory))
        let claudeUsage = LocalUsageModel(reader: RenderUsage(history: claudeHistory))
        codexUsage.refresh(); claudeUsage.refresh()

        let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: RenderCues())
        sessions.setMonitoredProviders([.codex, .claude])
        let phases: [SessionPhase] = [.running, .idle(completedTurnID: "turn"), .approval]
        for provider in [SessionProvider.codex, .claude] {
            for (index, id) in (provider == .codex ? ids : claudeIDs).enumerated() {
                sessions.receive(.init(observation: .init(sessionID: id, connectionID: UUID(),
                                                          liveness: .unverified, phase: phases[index % phases.count]),
                                       project: index == 0 ? "lunlet" : "synthetic-project-\(index)", outcome: .succeeded,
                                       turnID: "turn-\(provider.rawValue)-\(index)", activityConfirmed: true,
                                       lastActivityAt: now.addingTimeInterval(-Double(index + 1) * 140),
                                       localPreview: "Synthetic \(provider.shortName) conversation \(index + 1)",
                                       provider: provider), origin: .snapshot)
            }
        }
        if showHistory { sessions.clearDisplayedSessions(provider: tab) }
        let deadline = ContinuousClock.now + .seconds(2)
        while (codexUsage.snapshot == nil || claudeUsage.snapshot == nil || usage.state == .loading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let hover = UsageHoverPanelController(observesSystemEvents: false)
        let claudeHover = UsageHoverPanelController(observesSystemEvents: false)
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RenderPower())
        let panel = CompanionPanel(preferences: preferences, skins: SkinCatalog(directory: skinDirectory),
                                   setup: FeishuSetupModel(store: RenderEnrollmentStore()),
                                   botSetup: BotChannelSetupModel(storeFactory: { _ in RenderCredentialStore() }),
                                   notifications: notifications, usage: usage, sessions: sessions, history: codexUsage,
                                   usageHover: hover, claudeHistory: claudeUsage, claudeUsageHover: claudeHover,
                                   refresh: {}, openingTab: tab, openingHistory: showHistory, openingSettings: settings)
        let width = PanelPlacement.panelWidth
        let tabRow = settings == nil
        let height = PanelStyle.Layout.panelHeight(notchHeight: Self.notch.height, tabRow: tabRow)
        let side = (width - Self.notch.width) / 2
        let band = NotchBand(height: Self.notch.height, leading: side, trailing: side)
        let root = panel.environment(\.notchBand, band).environment(\.claudePlanLimits, limits).environment(\.appUpdater, updater)
            .frame(width: width, height: height)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            .overlay(alignment: .top) {
                // The hardware notch, drawn so the band layout can be judged.
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black)
                    .frame(width: Self.notch.width, height: Self.notch.height)
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
                .background(dark ? Color(white: 0.16) : Color(white: 0.93)).environment(\.colorScheme, dark ? .dark : .light)
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
        hover.shutdown(); claudeHover.shutdown(); sessions.shutdown()
        await codexUsage.shutdown(); await claudeUsage.shutdown(); await usage.shutdown(); await notifications.shutdown()
    }
}
