// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05; US-12, AC-12.04; US-32, AC-32.07.
import Foundation
import Testing
@testable import LunletCore
@testable import LunletCodex
@testable import LunletDesktop

private actor UsageReader: CodexAccountReading {
    let snapshot: AccountLimitsSnapshot
    let blocked: Bool
    private(set) var reads = 0
    private var failNext = false

    init(blocked: Bool = false, snapshot: AccountLimitsSnapshot? = nil) throws {
        self.snapshot = try snapshot ?? AccountLimitsDecoder.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8),
                                                                     observedAt: Date(timeIntervalSince1970: 1_800_000_000))
        self.blocked = blocked
    }

    func failFollowingRead() { failNext = true }
    func readLimits() async throws -> AccountLimitsSnapshot {
        reads += 1
        if blocked { try await Task.sleep(for: .seconds(60)) }
        if failNext { throw CodexAccountFailure.requestFailed }
        return snapshot
    }
}

@MainActor private func eventually(_ expected: AccountUsageModel.State, in model: AccountUsageModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.state != expected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == expected)
}

@Test @MainActor func usageStartsAutomaticallyOnceWithoutAnEnableSwitch() async throws {
    // AC-04.04: Runtime startup initiates one read, with no user enable action.
    let reader = try UsageReader()
    let model = AccountUsageModel(client: reader)
    model.start()
    try await eventually(.available(reader.snapshot), in: model)
    model.start()
    #expect(await reader.reads == 1)
    await model.shutdown()
}

@Test @MainActor func shuttingDownUsageCancelsTheReadAndPermanentlyClosesIt() async throws {
    // AC-04.04, AC-04.05, AC-12.04: Concurrent attempts and post-quit reads are suppressed.
    let reader = try UsageReader(blocked: true)
    let model = AccountUsageModel(client: reader)
    model.start()
    let deadline = ContinuousClock.now + .seconds(10)
    while await reader.reads == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    model.refresh()
    model.refreshIfNeeded()
    model.start()
    #expect(await reader.reads == 1)
    await model.shutdown()
    #expect(model.state == .disabled)
    model.start()
    model.refresh()
    model.refreshIfNeeded()
    await Task.yield()
    #expect(await reader.reads == 1)
    #expect(model.state == .disabled)
}

@Test @MainActor func panelOpeningRefreshesOnlyAfterFiveMinutesIncludingFailedAttempts() async throws {
    // AC-04.03, AC-04.05: An unavailable account cannot cause repeated reads on every panel opening.
    let reader = try UsageReader()
    var now = ContinuousClock.now
    let model = AccountUsageModel(client: reader, now: { now })
    model.start()
    try await eventually(.available(reader.snapshot), in: model)
    now += .seconds(299)
    model.refreshIfNeeded()
    #expect(model.state == .available(reader.snapshot))
    #expect(await reader.reads == 1)
    await reader.failFollowingRead()
    now += .seconds(1)
    model.refreshIfNeeded()
    try await eventually(.unavailable, in: model)
    #expect(await reader.reads == 2)
    model.refreshIfNeeded()
    #expect(model.state == .unavailable)
    #expect(await reader.reads == 2)
    now += .seconds(300)
    model.refreshIfNeeded()
    try await eventually(.unavailable, in: model)
    #expect(await reader.reads == 3)
    await model.shutdown()
}

@Test @MainActor func manualRefreshBypassesThrottleAndDoesNotPresentAnOlderSnapshotAfterFailure() async throws {
    // AC-04.01, AC-04.03: A requested refresh can run immediately, but old data cannot appear current.
    let reader = try UsageReader()
    let model = AccountUsageModel(client: reader)
    model.start()
    try await eventually(.available(reader.snapshot), in: model)
    await reader.failFollowingRead()
    model.refresh()
    #expect(model.displayedSnapshot == reader.snapshot)
    try await eventually(.unavailable, in: model)
    #expect(model.displayedSnapshot == nil)
    #expect(await reader.reads == 2)
    await model.shutdown()
}

@Test @MainActor func failedReadKeepsTheWeeklyTrendAndMarksItStale() async throws {
    // AC-32.07: a failed read keeps the estimate built from earlier readings and labels it stale.
    let weekly = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"limitId":"codex","secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1800500000}}}
        """.utf8), observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8))
    let reader = try UsageReader(snapshot: weekly)
    let model = AccountUsageModel(client: reader)
    model.start()
    try await eventually(.available(weekly), in: model)
    #expect(!model.latestReadFailed && model.weeklyTrend.readings.count == 1)
    await reader.failFollowingRead()
    model.refresh()
    try await eventually(.unavailable, in: model)
    #expect(model.latestReadFailed && model.weeklyTrend.readings.count == 1 && model.weeklyTrend.resetAt != nil)
    await model.shutdown()
    #expect(!model.latestReadFailed && model.weeklyTrend.readings.isEmpty)
}
