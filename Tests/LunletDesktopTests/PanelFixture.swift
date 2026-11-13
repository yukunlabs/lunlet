// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.09; US-04, AC-04.17; US-19, AC-19.09; US-24, AC-24.01.
import AppKit
import SwiftUI
import Testing
import LunletClaude
import LunletCodex
import LunletCore
import LunletFeishu
import LunletMessaging
@testable import LunletDesktop

// Synthetic models for the real panel content: no account read, Keychain, network or session source. Shared by the
// page renders, the layout checks and the product film render.
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

/// The real panel over synthetic models, in the state a test or a render asks for.
@MainActor final class PanelFixture {
    /// What the Codex account reports.
    enum Account {
        /// A paid plan with both windows, Credits and two reset entitlements.
        case typical
        /// A free plan that reports no window at all, with long figures: a credit
        /// balance with cents and a far expiry.
        case longFigures

        func limits(epoch: Int) -> String {
            switch self {
            case .typical:
                """
                {"rateLimits":{"primary":{"usedPercent":41,"windowDurationMins":300,"resetsAt":\(epoch + 2*3600 + 20*60)},"secondary":{"usedPercent":38,"windowDurationMins":10080,"resetsAt":\(epoch + 4*86400 + 3*3600)},"credits":{"balance":"75000.000000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 3*86400 + 4*3600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 11*86400 + 8*3600)}]}}
                """
            case .longFigures:
                """
                {"rateLimits":{"credits":{"balance":"1234567.890000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":10,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 26*86400 + 13*3600 + 600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 29*86400)}]}}
                """
            }
        }
        var identity: String {
            switch self {
            case .typical: #"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#
            case .longFigures: #"{"account":{"type":"chatgpt","email":"a-rather-long-synthetic-address@example.invalid","planType":"free"}}"#
            }
        }
    }

    let preferences: PreferencesStore
    let skins: SkinCatalog
    let usage: AccountUsageModel
    let codexUsage: LocalUsageModel
    let claudeUsage: LocalUsageModel
    let sessions: SessionListModel
    let hover = UsageHoverPanelController(observesSystemEvents: false)
    let claudeHover = UsageHoverPanelController(observesSystemEvents: false)
    let notifications = LockedCompletionNotifications(isLocked: { false }, power: RenderPower())
    private let suite: String
    private let defaults: UserDefaults
    private let skinDirectory: URL

    /// `count` sessions per agent; `titles` replace the synthetic conversation titles in order.
    init(sessions count: Int, account: Account = .typical, titles: [String] = []) async throws {
        suite = "com.lunlet.test.render.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        skinDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-render-\(UUID())")
        preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.providers = [.codex, .claude] }
        skins = SkinCatalog(directory: skinDirectory)

        let now = Date(), epoch = Int(now.timeIntervalSince1970)
        let snapshot = try AccountLimitsDecoder.decode(Data(account.limits(epoch: epoch).utf8), observedAt: now.addingTimeInterval(-120),
                                                       accountData: Data(account.identity.utf8))
        usage = AccountUsageModel(client: RenderAccount(snapshot: snapshot))
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
        codexUsage = LocalUsageModel(reader: RenderUsage(history: codexHistory))
        claudeUsage = LocalUsageModel(reader: RenderUsage(history: claudeHistory))
        codexUsage.refresh(); claudeUsage.refresh()

        sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: RenderCues())
        sessions.setMonitoredProviders([.codex, .claude])
        let phases: [SessionPhase] = [.running, .idle(completedTurnID: "turn"), .approval]
        for provider in [SessionProvider.codex, .claude] {
            for (index, id) in (provider == .codex ? ids : claudeIDs).enumerated() {
                sessions.receive(.init(observation: .init(sessionID: id, connectionID: UUID(),
                                                          liveness: .unverified, phase: phases[index % phases.count]),
                                       project: index == 0 ? "lunlet" : "synthetic-project-\(index)", outcome: .succeeded,
                                       turnID: "turn-\(provider.rawValue)-\(index)", activityConfirmed: true,
                                       lastActivityAt: now.addingTimeInterval(-Double(index + 1) * 140),
                                       localPreview: index < titles.count ? titles[index]
                                           : "Synthetic \(provider.shortName) conversation \(index + 1)",
                                       provider: provider), origin: .snapshot)
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while (codexUsage.snapshot == nil || claudeUsage.snapshot == nil || usage.state == .loading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The panel opened on a page: an agent's, optionally its History, or a Settings category; none is the Overview.
    func panel(tab: SessionProvider? = nil, history: Bool = false, settings: PreferenceCategory? = nil) -> CompanionPanel {
        if history { sessions.clearDisplayedSessions(provider: tab) }
        return CompanionPanel(preferences: preferences, skins: skins,
                              setup: FeishuSetupModel(store: RenderEnrollmentStore()),
                              botSetup: BotChannelSetupModel(storeFactory: { _ in RenderCredentialStore() }),
                              notifications: notifications, usage: usage, sessions: sessions, history: codexUsage,
                              usageHover: hover, claudeHistory: claudeUsage, claudeUsageHover: claudeHover,
                              refresh: {}, openingTab: tab, openingHistory: history, openingSettings: settings)
    }

    func shutdown() async {
        hover.shutdown(); claudeHover.shutdown(); sessions.shutdown()
        await codexUsage.shutdown(); await claudeUsage.shutdown(); await usage.shutdown(); await notifications.shutdown()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: skinDirectory)
    }
}

@MainActor private final class LaidOutSizeBox { var size = CGSize.zero }

/// The size a view takes when its container offers `size`: wider than the offer means the view cannot shrink to it.
@MainActor func laidOutSize(of view: some View, offered size: CGSize) async throws -> CGSize {
    let box = LaidOutSizeBox()
    let hosting = NSHostingView(rootView: view.background(GeometryReader { geometry in
        Color.clear.onChange(of: geometry.size, initial: true) { _, new in box.size = new }
    }))
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    hosting.layoutSubtreeIfNeeded()
    return box.size
}
