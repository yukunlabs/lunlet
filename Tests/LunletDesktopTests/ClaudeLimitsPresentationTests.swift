// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.09, AC-33.10; US-32, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
// Refs: US-19, AC-19.04, AC-19.05; US-04, AC-04.03.
import Foundation
import Testing
import LunletClaude
import LunletCodex
import LunletCore
@testable import LunletDesktop

/// A connected synthetic Claude configuration whose status-line files the test writes directly.
@MainActor struct ClaudeLimitsFixture {
    let root: URL
    let connection: ClaudeStatusLineConnection
    init(settings: String = "{\n  \"theme\": \"dark\"\n}\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-limits-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: claude.appendingPathComponent("settings.json"))
        connection = .init(home: .init(root: claude), location: .init(directory: root.appendingPathComponent("support")))
    }
    var settings: String? { try? String(contentsOf: connection.home.settings, encoding: .utf8) }
    func write(state: String, log: String? = nil) throws {
        try Data(state.utf8).write(to: connection.location.limits)
        if let log { try Data(log.utf8).write(to: connection.location.weeklyLog) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    /// Waits for the model's background read to publish.
    static func settle(_ model: ClaudePlanLimitsModel, until done: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor @Suite struct ClaudeLimitsPresentationTests {
    let now = Date(timeIntervalSince1970: 1_793_390_400)  // Fri 2026-10-30 20:00 UTC
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value }
    private func reading(_ used: Double, resetIn: TimeInterval, age: TimeInterval = 0) -> LimitWindowReading {
        .init(usedPercent: used, resetsAt: now.addingTimeInterval(resetIn), at: now.addingTimeInterval(-age))
    }
    private func moment(_ date: Date) -> String { ClaudeLimitsText.moment(date, now: now, calendar: calendar) }

    // Refs: US-33, AC-33.09; US-04, AC-04.03.
    @Test func windowsReadAsPercentLeftLikeCodexAndUnknownStaysUnknown() {
        let session = reading(47.9, resetIn: 1_800)
        // Remaining, as Codex shows it: 100 minus the reported percent used.
        #expect(ClaudeLimitsText.left(session, now: now) == "52% left" && ClaudeLimitsText.remaining(session, now: now) == 100 - 47.9)
        #expect(ClaudeLimitsText.left(reading(100, resetIn: 60), now: now) == "0% left")
        // A nearly exhausted window is never shown as exhausted before it is.
        #expect(ClaudeLimitsText.left(reading(99.9, resetIn: 60), now: now) == "<1% left")
        #expect(ClaudeLimitsText.left(reading(0, resetIn: 60), now: now) == "100% left")
        #expect(ClaudeLimitsText.left(nil, now: now) == "—")
        // A window whose reset has passed no longer describes current use.
        #expect(ClaudeLimitsText.left(reading(80, resetIn: -60), now: now) == "—" && ClaudeLimitsText.remaining(reading(80, resetIn: -60), now: now) == nil)
        #expect(ClaudeLimitsText.resetLine(reading(80, resetIn: -60), now: now) == "reset due")
        #expect(ClaudeLimitsText.resetLine(nil, now: now) == "reset —")
        #expect(ClaudeLimitsText.resetLine(session, now: now, calendar: calendar) == "resets " + moment(session.resetsAt))
        let week = reading(13, resetIn: 3 * 86_400)
        #expect(moment(week.resetsAt) == week.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        // The reading's age appears once it is more than a minute old.
        let fresh = ClaudePlanLimits(fiveHour: reading(1, resetIn: 60, age: 30), sevenDay: nil, weekly: [])
        #expect(ClaudeLimitsText.asOf(fresh, now: now) == nil)
        let older = ClaudePlanLimits(fiveHour: reading(1, resetIn: 60, age: 600), sevenDay: nil, weekly: [])
        #expect(ClaudeLimitsText.asOf(older, now: now, calendar: calendar) == "as of " + moment(now.addingTimeInterval(-600)))
        #expect(ClaudeLimitsText.asOf(nil, now: now) == nil)
    }

    // Refs: US-32, AC-32.05, AC-32.06, AC-32.08; US-33, AC-33.09.
    @Test func theWeeklyWindowFeedsTheProviderIndependentEstimator() {
        func limits(_ points: [(TimeInterval, Double)], resetIn: TimeInterval = 3 * 86_400) -> ClaudePlanLimits {
            let reset = now.addingTimeInterval(resetIn)
            let weekly = points.map { QuotaReading(at: now.addingTimeInterval(-$0.0), remaining: 100 - $0.1, resetAt: reset) }
            let last = points.last!
            return .init(fiveHour: nil, sevenDay: .init(usedPercent: last.1, resetsAt: reset, at: now.addingTimeInterval(-last.0)),
                         weekly: weekly)
        }
        // A window that began three hours ago, with no earlier window: too early.
        let young = limits([(7_200, 4), (0, 5)], resetIn: 7 * 86_400 - 3 * 3_600)
        guard case .tooEarly = ClaudeLimitsText.pace(young, now: now)?.forecast else { Issue.record("expected too early"); return }
        // Four days of steady use since the window began: an estimate with an even-pace comparison. At this pace the
        // central estimate just lasts while the fast end runs out, which the shared wording states as an estimate.
        let steady = limits([(4 * 86_400 - 3_600, 1), (3 * 86_400, 14), (2 * 86_400, 28), (86_400, 42), (0, 56)])
        let pace = ClaudeLimitsText.pace(steady, now: now)
        guard case .estimate(let estimate) = pace?.forecast else { Issue.record("expected an estimate"); return }
        #expect(estimate.runOut == nil && estimate.earliestRunOut != nil)
        // The forecast reads in the shared remaining-terms wording, the same as Codex's.
        #expect(QuotaForecastText.header(pace, stale: false, now: now).contains("% at reset"))
        #expect(pace?.evenPace.map { abs($0 - 100 * 3 / 7) < 0.01 } == true)
        // A 100% reading is the observed run-out, not a projection.
        guard case .exhausted = ClaudeLimitsText.pace(limits([(86_400, 90), (3_600, 100)]), now: now)?.forecast else {
            Issue.record("expected exhausted"); return
        }
        // Without a weekly window there is no forecast.
        #expect(ClaudeLimitsText.pace(.init(fiveHour: nil, sevenDay: nil, weekly: []), now: now) == nil)
    }

    // Refs: US-33, AC-33.10; US-19, AC-19.05.
    @Test func claudeUsageLeadsWithCostAndListsCategoriesWhileTotalsStayUnchanged() {
        let categories = LocalTokenBreakdown(input: 1_200, output: 45_000, cacheWrite: 120_000, cacheRead: 3_400_000)
        let claude = LocalUsageAmount(tokens: 3_566_200, estimatedUSD: 4.12, partial: true, breakdown: categories)
        #expect(ClaudeLimitsText.breakdown(claude) == "in 1.2K · out 45K · cache write 120K · cache read 3.4M")
        #expect(ClaudeLimitsText.breakdown(claude, compact: true) == "in 1.2K · out 45K")
        #expect(ClaudeLimitsText.spokenBreakdown(claude)?.hasPrefix("input 1200, output 45000") == true)
        // Codex records only totals, so it shows none and its presentation is unchanged.
        let codex = LocalUsageAmount(tokens: 2_000, estimatedUSD: 1.5, partial: false)
        #expect(ClaudeLimitsText.breakdown(codex) == nil && LocalUsageText.tokens(codex) == "2K tokens")
        // Overview totals add tokens and cost exactly as before; categories are not combined across providers.
        let total = OverviewUsage.combined([codex, claude])
        #expect(total?.tokens == 3_568_200 && total?.estimatedUSD == 5.62 && total?.breakdown == nil)
    }

    // Refs: US-33, AC-33.08, AC-33.09; US-32, AC-32.07.
    @Test func theModelConnectsReadsAndKeepsAnEarlierReadingWhenARereadFails() async throws {
        let fixture = try ClaudeLimitsFixture(); defer { fixture.remove() }
        let model = ClaudePlanLimitsModel(service: fixture.connection)
        // Inactive while Claude Code is not a selected agent: nothing is read until Settings asks.
        model.refresh()
        #expect(model.connection == .checking)
        model.check()
        try await ClaudeLimitsFixture.settle(model) { model.connection != .checking }
        #expect(model.connection == .notConnected && model.limits == nil)
        model.connect()
        try await ClaudeLimitsFixture.settle(model) { model.connection == .connected && !model.isChanging }
        #expect(model.connection == .connected && fixture.settings?.contains("\"statusLine\"") == true)
        let t = Int(Date().timeIntervalSince1970)
        try fixture.write(state: "lunlet-claude-limits 1\nfive_hour 47 \(t + 3_600) \(t - 5)\nseven_day 13 \(t + 86_400) \(t - 5)\n")
        model.setActive(true)
        try await ClaudeLimitsFixture.settle(model) { model.limits?.fiveHour != nil }
        #expect(model.limits?.fiveHour?.usedPercent == 47 && model.limits?.sevenDay?.usedPercent == 13 && !model.readFailed)
        // A damaged reading file keeps the earlier values, labeled stale, instead of inventing zero.
        try fixture.write(state: "lunlet-claude-limits 9\n")
        model.refresh()
        try await ClaudeLimitsFixture.settle(model) { model.readFailed }
        #expect(model.readFailed && model.limits?.fiveHour?.usedPercent == 47)
        model.disconnect()
        try await ClaudeLimitsFixture.settle(model) { model.connection == .notConnected && !model.isChanging }
        #expect(fixture.settings == "{\n  \"theme\": \"dark\"\n}\n" && model.limits == nil)
        await model.shutdown()
    }

    // Refs: US-33, AC-33.08. While Claude Code is selected the status line connects on its own and says so once; an
    // explicit disconnect is remembered across launches until an explicit connect.
    @Test func plansLimitsConnectAutomaticallyUntilTheOwnerDisconnects() async throws {
        let fixture = try ClaudeLimitsFixture(); defer { fixture.remove() }
        let suite = "com.lunlet.test.claude-auto.\(UUID())", choices = try #require(UserDefaults(suiteName: suite))
        defer { choices.removePersistentDomain(forName: suite) }
        let model = ClaudePlanLimitsModel(service: fixture.connection, connectsAutomatically: true, choices: choices)
        model.setActive(true)
        try await ClaudeLimitsFixture.settle(model) { model.connection == .connected && model.addedAutomatically }
        #expect(model.addedAutomatically && fixture.settings?.contains("\"statusLine\"") == true)
        // The note lasts one panel visit.
        model.setWatching(true); model.setWatching(false)
        #expect(!model.addedAutomatically)
        model.disconnect()
        try await ClaudeLimitsFixture.settle(model) { model.connection == .notConnected && !model.isChanging }
        #expect(choices.bool(forKey: ClaudePlanLimitsModel.declinedKey) && fixture.settings == "{\n  \"theme\": \"dark\"\n}\n")
        await model.shutdown()
        // A later launch leaves it off, until the owner connects again.
        let relaunched = ClaudePlanLimitsModel(service: fixture.connection, connectsAutomatically: true, choices: choices)
        relaunched.setActive(true)
        try await ClaudeLimitsFixture.settle(relaunched) { relaunched.connection != .checking }
        try await Task.sleep(for: .milliseconds(100))
        #expect(relaunched.connection == .notConnected && fixture.settings == "{\n  \"theme\": \"dark\"\n}\n")
        relaunched.connect()
        try await ClaudeLimitsFixture.settle(relaunched) { relaunched.connection == .connected && !relaunched.isChanging }
        #expect(!choices.bool(forKey: ClaudePlanLimitsModel.declinedKey) && !relaunched.addedAutomatically)
        // The agent switch is the only control: turning Claude Code off restores the previous status line exactly, and
        // turning it on connects again.
        relaunched.setActive(false)
        try await ClaudeLimitsFixture.settle(relaunched) { fixture.settings == "{\n  \"theme\": \"dark\"\n}\n" && !relaunched.isChanging }
        #expect(fixture.settings == "{\n  \"theme\": \"dark\"\n}\n")
        relaunched.setActive(true)
        try await ClaudeLimitsFixture.settle(relaunched) { relaunched.connection == .connected && !relaunched.isChanging }
        #expect(fixture.settings?.contains("\"statusLine\"") == true)
        relaunched.setActive(false)
        try await ClaudeLimitsFixture.settle(relaunched) { fixture.settings == "{\n  \"theme\": \"dark\"\n}\n" && !relaunched.isChanging }
        await relaunched.shutdown()
    }
}
