// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.05, AC-32.06, AC-32.07; US-04, AC-04.08.
import AppKit
import SwiftUI
import Foundation
import Testing
import LunletCore
import LunletCodex
@testable import LunletDesktop

/// Returns each synthetic snapshot once, then fails, like an account read after the network drops.
private actor TrendPanelAccount: CodexAccountReading {
    let snapshots: [AccountLimitsSnapshot]
    var index = 0
    init(_ snapshots: [AccountLimitsSnapshot]) { self.snapshots = snapshots }
    func readLimits() async throws -> AccountLimitsSnapshot {
        defer { index += 1 }
        guard index < snapshots.count else { throw CodexAccountFailure.requestFailed }
        return snapshots[index]
    }
}
private struct TrendPanelHistory: LocalUsageReading {
    let value: LocalUsageHistory
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory { value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor func quotaAndLocalUsageFitTheSameHoverPanel() async throws {
    _ = NSApplication.shared
    let now = Date(), reset = Int(now.addingTimeInterval(6 * 86_400).timeIntervalSince1970)
    let accountData = Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8)
    let snapshots = try [(0.0, 80.0), (0.5, 70.0), (1.0, 60.0)].map { hours, remaining in
        let json = Data("""
        {"rateLimits":{"limitId":"codex","secondary":{"usedPercent":\(100 - remaining),"windowDurationMins":10080,"resetsAt":\(reset)}}}
        """.utf8)
        return try AccountLimitsDecoder.decode(json, observedAt: now.addingTimeInterval((hours - 1) * 3600), accountData: accountData)
    }
    let account = AccountUsageModel(client: TrendPanelAccount(snapshots))
    for index in 0..<4 {
        if index == 0 { account.start() } else { account.refresh() }
        let deadline = ContinuousClock.now + .seconds(2)
        while account.state == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }
    // The fourth read fails; the trend and its estimate stay, labeled stale.
    #expect(account.state == .unavailable && account.latestReadFailed)
    #expect(account.weeklyTrend.readings.count == 3)
    let days = (0..<5).map { index in
        LocalUsageDay(date: Calendar.current.date(byAdding: .day, value: index - 4, to: now)!,
            amount: LocalUsageAmount(tokens: Int64((index + 1) * 1_000_000), estimatedUSD: Double(index + 1), partial: false))
    }
    let localQuota = [LocalQuotaObservation(at: now.addingTimeInterval(-23 * 3600), resetAt: Date(timeIntervalSince1970: Double(reset)),
                                            remaining: 98, bucketID: "codex", plan: "pro")]
    // The longest header: a rough run-out with its earliest time and a stale suffix.
    let display = account.weeklyTrend.display(local: localQuota, now: now)
    let header = QuotaForecastText.header(display.pace, stale: true, now: now)
    #expect(header.hasPrefix("Rough · May run out ~") && header.contains("(earliest ") && header.contains(" · stale, as of "))
    #expect(QuotaForecastText.evenPace(display.pace, now: now)?.hasPrefix("Even pace ") == true)
    let history = LocalUsageModel(reader: TrendPanelHistory(value: .init(days: days, sessions: [:], partial: true, quotaHistory: localQuota)))
    history.refresh()
    let deadline = ContinuousClock.now + .seconds(2)
    while history.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let view = NSHostingView(rootView: UsageOverviewPanel(account: account, history: history)
        .frame(width: 320, height: 357).background(Color(white: 0.14)).environment(\.colorScheme, .dark))
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 357); view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height <= 357)
    if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1" {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/quota-trend-panel.png"))
    }
    await history.shutdown(); await account.shutdown()
}
