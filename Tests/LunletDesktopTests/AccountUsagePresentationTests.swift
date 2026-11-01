// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.08, AC-04.09.
import AppKit
import SwiftUI
import Foundation
import LunletCodex
import Testing
@testable import LunletCore
@testable import LunletDesktop

@Suite struct AccountUsagePresentationTests {
    private func snapshot(_ json: String) throws -> AccountLimitsSnapshot {
        try AccountLimitsDecoder.decode(Data(json.utf8), observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func weeklyWindowUsesDurationInEitherPositionAndIdentifiesItsBucket() throws {
        // AC-04.07: A five-hour primary window is never substituted for the weekly window.
        for slot in ["primary", "secondary"] {
            let other = slot == "primary" ? "secondary" : "primary"
            let value = try snapshot("""
            {"rateLimits":{"limitName":"Synthetic allowance","\(slot)":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1800000600},"\(other)":{"usedPercent":90,"windowDurationMins":300}}}
            """)
            let weekly = try #require(AccountUsagePresentation.weekly(in: value))
            #expect(weekly.bucketName == "Synthetic allowance")
            #expect(weekly.remainingPercent == 77)
            #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_000_600))
        }
    }

    @Test func absentOrAmbiguousWeeklyWindowsStayUnavailable() throws {
        // AC-04.03, AC-04.07: No inferred week and no arbitrary bucket selection.
        let fixtures = [
            #"{}"#,
            #"{"rateLimits":{"secondary":{"usedPercent":25}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080},"secondary":{"usedPercent":50,"windowDurationMins":10080}}}"#,
            #"{"rateLimitsByLimitId":{"synthetic-a":{"primary":{"usedPercent":25,"windowDurationMins":10080}},"synthetic-b":{"secondary":{"usedPercent":50,"windowDurationMins":10080}}}}"#
        ]
        for fixture in fixtures {
            #expect(AccountUsagePresentation.weekly(in: try snapshot(fixture)) == nil)
        }
    }

    @Test func theDefaultCodexBucketIdentifiesTheWeeklyWindowAmongModelBuckets() throws {
        // AC-04.07: a model-specific weekly bucket does not hide the account's default Codex window.
        let value = try snapshot(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1800000600}},"model-special":{"limitName":"Special model","secondary":{"usedPercent":80,"windowDurationMins":10080}}}}"#)
        let weekly = try #require(AccountUsagePresentation.weekly(in: value))
        #expect(weekly.bucketID == "codex" && weekly.remainingPercent == 70)
        let twoCodexWindows = try snapshot(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":10080},"secondary":{"usedPercent":50,"windowDurationMins":10080}},"model-special":{"secondary":{"usedPercent":80,"windowDurationMins":10080}}}}"#)
        #expect(AccountUsagePresentation.weekly(in: twoCodexWindows) == nil)
    }

    @Test func unknownWeeklyUsageStaysUnknown() throws {
        // AC-04.03, AC-04.07: The presentation preserves missing weekly usage and reset fields.
        let unknown = try snapshot(#"{"rateLimits":{"secondary":{"windowDurationMins":10080}}}"#)
        let unknownWeekly = try #require(AccountUsagePresentation.weekly(in: unknown))
        #expect(unknownWeekly.remainingPercent == nil)
        #expect(unknownWeekly.resetsAt == nil)
    }

    @Test func resetCountdownUsesHoursAndDoesNotPretendAnElapsedQuotaHasRenewed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(6 * 86400 + 17 * 3600 + 59), now: now) == "6d 17h")
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(3601), now: now) == "1h")
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(60), now: now) == "<1h")
        #expect(AccountUsagePresentation.countdown(until: now, now: now) == nil)
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(-3600), now: now) == nil)
    }

    @Test func resetCreditExpiryIsSortedDeduplicatedAndNeverGuessesMissingDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let value = try snapshot(#"{"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"later","status":"available","expiresAt":1800360000},{"id":"soon","status":"available","expiresAt":1800090000},{"id":"soon","status":"available","expiresAt":1800090000},{"id":"used","status":"used","expiresAt":1800000100}]}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(value.earnedResets, now: now) == ["1d 1h", "4d 4h"])
        let partial = try snapshot(#"{"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"soon","status":"available","expiresAt":1800090000}]}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(partial.earnedResets, now: now) == ["1d 1h", "—"])
        #expect(AccountUsagePresentation.resetExpiryLabels(nil, now: now).isEmpty)
        let empty = try snapshot(#"{"rateLimitResetCredits":{"availableCount":0}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(empty.earnedResets, now: now).isEmpty)
    }


    @Test func relativeAccountFreshnessUsesTheActualSuccessTimestampAndCompactCreditValues() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated) == "Updated just now")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(125)) == "Updated 2m ago")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(7200)) == "Updated 2h ago")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(-60)) == nil)
        #expect(AccountUsagePresentation.creditBalance("75000.000000000000") == "75,000")
        #expect(AccountUsagePresentation.creditBalance("12.3456") == "12.35")
        #expect(AccountUsagePresentation.creditBalance("0.00001") == "<0.01")
        #expect(AccountUsagePresentation.creditBalance("0") == "0")
        #expect(AccountUsagePresentation.creditBalance("unknown") == "—")
    }

}

// Refs: US-04, AC-04.01, AC-04.03, AC-04.09; US-03, AC-03.09.
private actor SyntheticAccountCardReader: CodexAccountReading {
    let snapshot: AccountLimitsSnapshot
    init(snapshot: AccountLimitsSnapshot) { self.snapshot = snapshot }
    func readLimits() async throws -> AccountLimitsSnapshot { snapshot }
}
@MainActor private final class LayoutCueSink: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor func compactAccountCardFitsFreshnessBalanceAndTwoExpiryCountdowns() async throws {
    _ = NSApplication.shared
    let now = Date(), epoch = Int(now.timeIntervalSince1970)
    let snapshot = try AccountLimitsDecoder.decode(Data("""
    {"rateLimits":{"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":\(epoch + 6*86400 + 17*3600)},"credits":{"balance":"75000.000000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 3*86400 + 4*3600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 11*86400 + 8*3600)}]}}
    """.utf8), observedAt: now.addingTimeInterval(-120), accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8))
    let model = AccountUsageModel(client: SyntheticAccountCardReader(snapshot: snapshot))
    model.start()
    let deadline = ContinuousClock.now + .seconds(10)
    while model.state == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.displayedSnapshot == snapshot)
    let hover = UsageHoverPanelController()
    let hosting = NSHostingView(rootView: AccountUsageSummary(model: model, hoverPanel: hover)
        .frame(width: 446).background(Color(red: 0.13, green: 0.13, blue: 0.14)).environment(\.colorScheme, .dark))
    hosting.frame = .init(x: 0, y: 0, width: 446, height: 160)
    hosting.layoutSubtreeIfNeeded()
    #expect(hosting.fittingSize.height <= 160)
    let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: LayoutCueSink())
    for index in 0..<3 {
        let session = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running),
                                      project: "Synthetic project", title: "Session \(index)", turnID: "turn-\(index)")
        sessions.receive(session, origin: .snapshot)
    }
    let history = LocalUsageModel()
    let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: PanelStyle.Grid.margin) {
        AccountUsageSummary(model: model, hoverPanel: hover)
        SessionPanel(model: sessions, usage: history)
    }.frame(width: 446).fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14)).environment(\.colorScheme, .dark))
    content.frame = .init(x: 0, y: 0, width: 446, height: 300)
    content.layoutSubtreeIfNeeded()
    // The page between the header and footer below a 32-point notch.
    let available = PanelStyle.Layout.pageHeight
    #expect(content.fittingSize.height <= available, "content \(content.fittingSize.height) of \(available)")
    // Exactly three whole rows: a fourth may reveal only its blank top inset, never a sliver of text.
    #expect(available - content.fittingSize.height + PanelStyle.Layout.listVerticalInset <= PanelStyle.Layout.rowHighlightInset + 0.5)
    if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1",
       let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("codex-summary-preview.png"))
        if let layout = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: layout)
            try layout.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("codex-layout-preview.png"))
        }
    }
    hover.shutdown()
    sessions.shutdown()
    await history.shutdown()
    await model.shutdown()
}
