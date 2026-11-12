// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-41, AC-41.01, AC-41.02, AC-41.03, AC-41.04, AC-41.05; US-04, AC-04.01, AC-04.15.
import Foundation
import Testing
import LunletClaude
import LunletCodex
@testable import LunletCore
@testable import LunletDesktop

/// A deliverer that records what it was asked and answers with a fixed permission.
@MainActor private final class RecordingDeliverer: AllowanceNotificationDelivering {
    var state: AllowanceNotificationAuthorization
    private(set) var requests = 0
    private(set) var delivered: [AllowanceNotice] = []
    var activated: ((SessionProvider) -> Void)?
    init(state: AllowanceNotificationAuthorization) { self.state = state }
    func authorizationState() async -> AllowanceNotificationAuthorization { state }
    func requestAuthorization() async -> AllowanceNotificationAuthorization { requests += 1; return state }
    func deliver(_ notice: AllowanceNotice) async { delivered.append(notice) }
}

private actor FixedReader: CodexAccountReading {
    let snapshot: AccountLimitsSnapshot
    init(snapshot: AccountLimitsSnapshot) { self.snapshot = snapshot }
    func readLimits() async throws -> AccountLimitsSnapshot { snapshot }
}

@MainActor @Suite struct AllowanceNotificationsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func codex(_ json: String, observedAt: Date? = nil) throws -> AccountLimitsSnapshot {
        try AccountLimitsDecoder.decode(Data(json.utf8), observedAt: observedAt ?? now)
    }
    /// A weekly Codex window with the given percent left, read at `at`, resetting at `reset` (epoch seconds).
    private func weekly(left: Double, reset: TimeInterval, at: Date? = nil) throws -> [AllowanceReading] {
        let used = 100 - left
        return try AllowanceReading.codex(codex("""
        {"rateLimits":{"primary":{"usedPercent":\(used),"windowDurationMins":10080,"resetsAt":\(Int(reset))}}}
        """, observedAt: at), now: at ?? now)
    }
    private func claude(left: Double, resetIn: TimeInterval, age: TimeInterval = 0) -> ClaudePlanLimits {
        .init(sevenDay: .init(usedPercent: 100 - left, resetsAt: now.addingTimeInterval(resetIn), at: now.addingTimeInterval(-age)), weekly: [])
    }

    @Test func aWindowWarnsOnceWhenItDropsBelowTheLevelAndNotAgainWhileItStaysBelow() throws {
        // AC-41.03: one notice per crossing; the same window below the level again is silent.
        var rule = AllowanceAlertRule()
        let reset = now.timeIntervalSince1970 + 3 * 86_400
        #expect(rule.notices(for: try weekly(left: 45, reset: reset), warnBelow: 20, resetNotices: true, now: now).isEmpty)
        let first = rule.notices(for: try weekly(left: 18, reset: reset, at: now.addingTimeInterval(60)), warnBelow: 20,
                                 resetNotices: true, now: now.addingTimeInterval(60))
        #expect(first.count == 1)
        guard case .low(let reading)? = first.first else { Issue.record("expected a low-allowance notice"); return }
        #expect(reading.provider == .codex && reading.span == .weekly && reading.remainingPercent == 18)
        let again = rule.notices(for: try weekly(left: 9, reset: reset, at: now.addingTimeInterval(120)), warnBelow: 20,
                                 resetNotices: true, now: now.addingTimeInterval(120))
        #expect(again.isEmpty)
        // The same reading published twice is one reading.
        #expect(rule.notices(for: try weekly(left: 9, reset: reset, at: now.addingTimeInterval(120)), warnBelow: 20,
                             resetNotices: true, now: now.addingTimeInterval(120)).isEmpty)
    }

    @Test func aWindowWarnsAgainOnlyAfterALaterReadingShowsItAboveTheLevelOrReset() throws {
        // AC-41.03: re-armed by a reading above the level, or by a refreshed window.
        var rule = AllowanceAlertRule()
        let reset = now.timeIntervalSince1970 + 86_400
        _ = rule.notices(for: try weekly(left: 15, reset: reset), warnBelow: 20, resetNotices: false, now: now)
        _ = rule.notices(for: try weekly(left: 30, reset: reset, at: now.addingTimeInterval(60)), warnBelow: 20,
                         resetNotices: false, now: now.addingTimeInterval(60))
        let second = rule.notices(for: try weekly(left: 12, reset: reset, at: now.addingTimeInterval(120)), warnBelow: 20,
                                  resetNotices: false, now: now.addingTimeInterval(120))
        #expect(second.count == 1)
        // A new window after the reset moment that is already below the level is a new crossing.
        let after = now.addingTimeInterval(86_400 + 60)
        let fresh = rule.notices(for: try weekly(left: 10, reset: reset + 7 * 86_400, at: after), warnBelow: 20,
                                 resetNotices: false, now: after)
        #expect(fresh.count == 1)
        if case .low? = fresh.first {} else { Issue.record("a refreshed window below the level warns again") }
    }

    @Test func aResetNoticeNeedsAReadingAfterTheResetMomentThatShowsTheWindowRefreshed() throws {
        // AC-41.04: an elapsed reset alone sends nothing; a later reset moment or more allowance does, once.
        var rule = AllowanceAlertRule()
        let reset = now.timeIntervalSince1970 + 3_600
        _ = rule.notices(for: try weekly(left: 40, reset: reset), warnBelow: 20, resetNotices: true, now: now)
        // Still before the reset: nothing.
        #expect(rule.notices(for: try weekly(left: 38, reset: reset, at: now.addingTimeInterval(600)), warnBelow: 20,
                             resetNotices: true, now: now.addingTimeInterval(600)).isEmpty)
        let after = now.addingTimeInterval(3_700)
        // A reading after the reset moment that still shows the old window is stale, not a refresh.
        #expect(rule.notices(for: try weekly(left: 38, reset: reset, at: after), warnBelow: 20, resetNotices: true, now: after).isEmpty)
        let refreshed = rule.notices(for: try weekly(left: 100, reset: reset + 7 * 86_400, at: after), warnBelow: 20,
                                     resetNotices: true, now: after)
        #expect(refreshed.count == 1)
        guard case .reset(let reading)? = refreshed.first else { Issue.record("expected a reset notice"); return }
        #expect(reading.remainingPercent == 100)
        // The same refreshed window is reported once.
        #expect(rule.notices(for: try weekly(left: 99, reset: reset + 7 * 86_400, at: after.addingTimeInterval(60)), warnBelow: 20,
                             resetNotices: true, now: after.addingTimeInterval(60)).isEmpty)
        // With reset notices off the refresh is silent but still re-arms the warning.
        var quiet = AllowanceAlertRule()
        _ = quiet.notices(for: try weekly(left: 10, reset: reset), warnBelow: 20, resetNotices: false, now: now)
        #expect(quiet.notices(for: try weekly(left: 15, reset: reset + 7 * 86_400, at: after), warnBelow: 20,
                              resetNotices: false, now: after).count == 1)
    }

    @Test func staleUnknownAndMissingWindowsNeverNotify() throws {
        // AC-41.03: no reading, no percent, no reset time, a past reset or a disconnected Claude status line produce no reading.
        #expect(try AllowanceReading.codex(codex(#"{}"#), now: now).isEmpty)
        #expect(try AllowanceReading.codex(codex(#"{"rateLimits":{"primary":{"windowDurationMins":10080,"resetsAt":1800003600}}}"#), now: now).isEmpty)
        #expect(try AllowanceReading.codex(codex(#"{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":10080}}}"#), now: now).isEmpty)
        #expect(try weekly(left: 5, reset: now.timeIntervalSince1970 - 1).isEmpty)
        #expect(AllowanceReading.claude(nil, connected: true, now: now).isEmpty)
        #expect(AllowanceReading.claude(claude(left: 5, resetIn: 3_600), connected: false, now: now).isEmpty)
        #expect(AllowanceReading.claude(claude(left: 5, resetIn: -60), connected: true, now: now).isEmpty)
        let live = AllowanceReading.claude(claude(left: 5, resetIn: 3_600, age: 120), connected: true, now: now)
        #expect(live.count == 1 && live.first?.provider == .claude && live.first?.span == .weekly)
        #expect(live.first?.remainingPercent == 5 && live.first?.observedAt == now.addingTimeInterval(-120))
    }

    @Test func windowsAreTrackedIndependentlyAndTheFiveHourWindowIsIdentifiedByDuration() throws {
        // AC-41.03, AC-04.15: Codex's five-hour window warns on its own, found by its 300-minute duration in either position.
        for slot in ["primary", "secondary"] {
            var rule = AllowanceAlertRule()
            let other = slot == "primary" ? "secondary" : "primary"
            let readings = try AllowanceReading.codex(codex("""
            {"rateLimits":{"\(slot)":{"usedPercent":92,"windowDurationMins":300,"resetsAt":1800009000},"\(other)":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1800300000}}}
            """), now: now)
            #expect(Set(readings.map(\.span)) == [.fiveHour, .weekly])
            let notices = rule.notices(for: readings, warnBelow: 20, resetNotices: true, now: now)
            #expect(notices.count == 1)
            #expect(notices.first?.title == "Codex 5-hour window: 8% left")
        }
        // Claude's and Codex's weekly windows are different windows.
        var both = AllowanceAlertRule()
        _ = both.notices(for: try weekly(left: 10, reset: now.timeIntervalSince1970 + 86_400), warnBelow: 20, resetNotices: false, now: now)
        let claudeLow = both.notices(for: AllowanceReading.claude(claude(left: 10, resetIn: 86_400), connected: true, now: now),
                                     warnBelow: 20, resetNotices: false, now: now)
        #expect(claudeLow.count == 1 && claudeLow.first?.title == "Claude Code weekly allowance: 10% left")
    }

    @Test func noticesNameTheAgentAndWindowWithTheResetAndCarryNoAccountIdentity() throws {
        // AC-41.05, AC-04.01: the agent's name and the shared reset wording, stable identifiers, no account field.
        let reset = now.addingTimeInterval(33 * 3_600)
        let reading = try #require(try weekly(left: 0.4, reset: reset.timeIntervalSince1970).first)
        let low = AllowanceNotice.low(reading)
        #expect(low.title == "Codex weekly allowance: <1% left")
        #expect(low.body(now: now) == "Resets in 1d 9h · " + ClaudeLimitsText.moment(reset, now: now))
        #expect(low.identifier == "com.lunlet.allowance.codex.weekly.low")
        let fresh = AllowanceNotice.reset(reading)
        #expect(fresh.title == "Codex weekly allowance has reset")
        #expect(fresh.body(now: now) == "<1% left · resets " + ClaudeLimitsText.moment(reset, now: now))
        #expect(fresh.identifier == "com.lunlet.allowance.codex.weekly.reset")
        #expect(AllowanceNotice.provider(of: "com.lunlet.allowance.claude.weekly.low") == .claude)
        #expect(AllowanceNotice.provider(of: "something.else") == nil)
        let text = low.title + low.body(now: now)
        #expect(!text.contains("@") && !text.lowercased().contains("plan"))
    }

    @Test func theRuleSurvivesRelaunchSoAWindowIsNotReportedAgain() throws {
        // AC-41.03: the per-window memory is saved, so a relaunch does not repeat a notice for the same window.
        var rule = AllowanceAlertRule()
        let reset = now.timeIntervalSince1970 + 86_400
        #expect(rule.notices(for: try weekly(left: 12, reset: reset), warnBelow: 20, resetNotices: true, now: now).count == 1)
        let data = try JSONEncoder().encode(rule)
        var restored = try JSONDecoder().decode(AllowanceAlertRule.self, from: data)
        #expect(restored.notices(for: try weekly(left: 11, reset: reset, at: now.addingTimeInterval(60)), warnBelow: 20,
                                 resetNotices: true, now: now.addingTimeInterval(60)).isEmpty)
    }

    // MARK: Notifier

    private func store() throws -> (PreferencesStore, UserDefaults, String) {
        let suite = "com.lunlet.test.allowance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (PreferencesStore(defaults: defaults), defaults, suite)
    }

    @Test func nothingIsSentWhileTheSwitchIsOffOrPermissionIsMissing() async throws {
        // AC-41.01: off by default; turning on asks once; a denied permission sends nothing until it is granted.
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deliverer = RecordingDeliverer(state: .denied)
        let notifier = AllowanceNotifier(deliverer: deliverer, defaults: defaults, now: { self.now })
        notifier.observe(preferences: preferences)
        notifier.codexChanged(try codex("""
        {"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":\(Int(now.timeIntervalSince1970) + 86_400)}}}
        """))
        await notifier.settle()
        #expect(deliverer.requests == 0 && deliverer.delivered.isEmpty)
        preferences.update { $0.allowanceNotifications = true }
        await notifier.settle()
        #expect(deliverer.requests == 1 && deliverer.delivered.isEmpty && notifier.authorization == .denied)
        preferences.update { $0.allowanceWarnBelow = 30 }
        await notifier.settle()
        #expect(deliverer.requests == 1 && deliverer.delivered.isEmpty)
        // Permission granted later (System Settings): the next check lets the latest reading through, once.
        deliverer.state = .granted
        notifier.checkAuthorization()
        await notifier.settle()
        #expect(notifier.authorization == .granted && deliverer.delivered.count == 1)
        preferences.update { $0.allowanceNotifications = false }
        notifier.codexChanged(try codex("""
        {"rateLimits":{"primary":{"usedPercent":95,"windowDurationMins":10080,"resetsAt":\(Int(now.timeIntervalSince1970) + 86_400)}}}
        """, observedAt: now.addingTimeInterval(60)))
        await notifier.settle()
        #expect(deliverer.delivered.count == 1)
        await notifier.shutdown()
    }

    @Test func turningTheSwitchOnAsksForPermissionOnceAndReportsTheLatestReadingsOfBothAgents() async throws {
        // AC-41.01, AC-41.03, AC-41.05: one request, then the readings already held are evaluated; the Claude window too.
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deliverer = RecordingDeliverer(state: .granted)
        let notifier = AllowanceNotifier(deliverer: deliverer, defaults: defaults, now: { self.now })
        notifier.observe(preferences: preferences)
        notifier.claudeChanged(claude(left: 8, resetIn: 86_400), connected: true)
        notifier.codexChanged(try codex("""
        {"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":\(Int(now.timeIntervalSince1970) + 86_400)}}}
        """))
        await notifier.settle()
        #expect(deliverer.delivered.isEmpty)
        preferences.update { $0.allowanceNotifications = true }
        await notifier.settle()
        #expect(deliverer.requests == 1 && notifier.authorization == .granted)
        #expect(deliverer.delivered.map(\.title) == ["Claude Code weekly allowance: 8% left"])
        // A disconnected status line withdraws Claude's window without a notice of any kind.
        notifier.claudeChanged(claude(left: 8, resetIn: 86_400), connected: false)
        await notifier.settle()
        #expect(deliverer.delivered.count == 1)
        // Activating a notice opens that agent's page.
        var opened: [SessionProvider] = []
        notifier.openProvider = { opened.append($0) }
        deliverer.activated?(.claude)
        #expect(opened == [.claude])
        await notifier.shutdown()
    }

    @Test func readingsFlowFromTheAccountModelThroughTheSubscription() async throws {
        // AC-41.05: notices follow the readings the account model already takes; no extra read is requested.
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.update { $0.allowanceNotifications = true; $0.allowanceWarnBelow = 30 }
        let reader = FixedReader(snapshot: try codex("""
        {"rateLimits":{"primary":{"usedPercent":75,"windowDurationMins":10080,"resetsAt":\(Int(Date().timeIntervalSince1970) + 86_400)}}}
        """, observedAt: Date()))
        let usage = AccountUsageModel(client: reader)
        let deliverer = RecordingDeliverer(state: .granted)
        let notifier = AllowanceNotifier(deliverer: deliverer, defaults: defaults)
        notifier.observe(preferences: preferences)
        notifier.observe(usage: usage)
        usage.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while deliverer.delivered.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await notifier.settle()
        #expect(deliverer.delivered.map(\.title) == ["Codex weekly allowance: 25% left"])
        await notifier.shutdown()
        await usage.shutdown()
    }

    @Test func anActivatedNoticeFocusesTheAgentsPageInTheSessionModel() {
        // AC-41.05: the focus names the agent and changes every time, so the panel reacts to a repeat too; not after shutdown.
        let sessions = SessionListModel(presenter: SilentPresenter())
        sessions.focus(provider: .claude)
        let first = sessions.providerFocus
        #expect(first?.provider == .claude)
        sessions.focus(provider: .claude)
        #expect(sessions.providerFocus != first && sessions.providerFocus?.provider == .claude)
        sessions.shutdown()
        sessions.focus(provider: .codex)
        #expect(sessions.providerFocus?.provider == .claude)
    }
}

@MainActor private final class SilentPresenter: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}
