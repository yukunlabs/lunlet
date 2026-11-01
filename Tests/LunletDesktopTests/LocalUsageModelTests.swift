// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.05, AC-04.08, AC-04.10; US-12, AC-12.04.
// Refs: US-18, AC-18.01, AC-18.02, AC-18.03.
// Refs: US-25, AC-25.02.
// Refs: US-23, AC-23.01.
import Combine
import AppKit
import Foundation
import Testing
import SwiftUI
import LunletCodex
import LunletCore
@testable import LunletDesktop

private actor HistoryReader: LocalUsageReading {
    private(set) var reads = 0
    let blocked: Bool
    let history: LocalUsageHistory
    var fail = false
    init(blocked: Bool = false, history: LocalUsageHistory = .init(days: [], sessions: [:], partial: false)) {
        self.blocked = blocked; self.history = history
    }
    func failNext() { fail = true }
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory {
        reads += 1
        if blocked { try await Task.sleep(for: .seconds(60)) }
        if fail { throw LocalUsageReadFailure.unavailable }
        return history
    }
}

private actor RangeHistoryReader: LocalUsageReading {
    private(set) var requests: [Int] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?
    func release() { releaseFirst?.resume(); releaseFirst = nil }
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory {
        requests.append(days)
        if requests.count == 1 {
            // Deliberately ignores cancellation, like an in-flight file or network response.
            await withCheckedContinuation { releaseFirst = $0 }
        }
        let start = calendar.startOfDay(for: now)
        return .init(days: (0..<days).map {
            .init(date: calendar.date(byAdding: .day, value: -$0, to: start)!,
                  amount: .init(tokens: 1, estimatedUSD: nil, partial: false))
        }, sessions: [:], partial: false)
    }
}

@MainActor struct LocalUsageModelTests {
    @Test func freshnessTracksSuccessInsteadOfAttemptsFailuresOrCanceledReads() async throws {
        let reader = HistoryReader()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = LocalUsageModel(reader: reader, now: { now })
        #expect(subject.lastSuccessfulRefresh == nil)
        subject.refresh()
        #expect(subject.lastSuccessfulRefresh == nil)
        try await settle(subject)
        let success = now
        #expect(subject.lastSuccessfulRefresh == success)
        now = now.addingTimeInterval(600)
        await reader.failNext()
        subject.refresh()
        #expect(subject.lastSuccessfulRefresh == success)
        try await settle(subject)
        #expect(subject.lastSuccessfulRefresh == success && subject.unavailable)
        await subject.shutdown()

        let canceled = LocalUsageModel(reader: HistoryReader(blocked: true), now: { now })
        canceled.refresh()
        await canceled.shutdown()
        #expect(canceled.lastSuccessfulRefresh == nil)
    }

    @Test func refreshIsThrottledAndFailuresDoNotPresentOldHistoryAsCurrent() async throws {
        let reader = HistoryReader()
        let subject = LocalUsageModel(reader: reader)
        subject.refreshIfNeeded()
        try await settle(subject)
        #expect(subject.snapshot != nil && !subject.unavailable)
        subject.refreshIfNeeded()
        #expect(await reader.reads == 1)
        await reader.failNext()
        subject.refresh()
        try await settle(subject)
        #expect(subject.snapshot == nil && subject.unavailable)
        #expect(await reader.reads == 2)
        await subject.shutdown()
    }
    @Test func shutdownCancelsOwnedReadAndSuppressesDuplicateOrLateRefreshes() async throws {
        let reader = HistoryReader(blocked: true)
        let subject = LocalUsageModel(reader: reader)
        subject.refresh(); subject.refresh(); subject.refreshIfNeeded()
        let deadline = ContinuousClock.now + .seconds(10)
        while await reader.reads == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await reader.reads == 1)
        await subject.shutdown()
        subject.refresh(); subject.refreshIfNeeded()
        #expect(!subject.isLoading && subject.snapshot == nil)
        #expect(await reader.reads == 1)
    }

    // AC-18.01 through AC-18.03: a stale range cannot overwrite the new selection.
    @Test func changingRangeDiscardsLateReadAndPublishesOnlyTheLatestSelection() async throws {
        let reader = RangeHistoryReader()
        let subject = LocalUsageModel(reader: reader)
        var published: [Int] = []
        let subscription = subject.$snapshot.compactMap { $0?.days.count }.sink { published.append($0) }
        defer { subscription.cancel() }
        subject.refresh()
        let deadline = ContinuousClock.now + .seconds(10)
        while await reader.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await reader.requests == [5])
        subject.setHistoryDays(7)
        subject.setHistoryDays(0)
        #expect(subject.historyDays == 7)
        await reader.release()
        try await settle(subject)
        #expect(await reader.requests == [5, 7])
        #expect(published == [7])
        #expect(subject.snapshot?.days.count == 7)
        await subject.shutdown()
    }

    @Test func returningToTheOriginalRangeStillReplacesTheCanceledRead() async throws {
        let reader = RangeHistoryReader()
        let subject = LocalUsageModel(reader: reader)
        subject.refresh()
        let deadline = ContinuousClock.now + .seconds(10)
        while await reader.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        subject.setHistoryDays(7); subject.setHistoryDays(5)
        await reader.release()
        try await settle(subject)
        #expect(await reader.requests == [5, 5])
        #expect(subject.snapshot?.days.count == 5)
        await subject.shutdown()
    }

    // AC-04.02, AC-23.01: compact session amounts leave space for identity without hiding tiny usage.
    @Test func sessionCostTextRoundsTypicalAmountsWithoutRoundingTinyUsageToZero() {
        for (value, expected) in [(146.884524, "≈$146.88"), (12.345678, "≈$12.35"),
                                  (1234.5678, "≈$1,234.57"), (0.01, "≈$0.01"), (0, "≈$0.00"),
                                  (0.0003, "≈$0.0003"), (0.000000000001, "≈$1e-12")] {
            #expect(LocalUsageText.cost(.init(tokens: 110, estimatedUSD: value, partial: false)) == expected)
        }
        let partial = LocalUsageAmount(tokens: 220, estimatedUSD: 146.884524, partial: false,
                                       pricedTokens: 110, unpricedTokens: 110)
        #expect(LocalUsageText.cost(partial) == "≥$146.88")
        #expect(LocalUsageText.costHelp(partial).contains("≥$146.884524 USD"))
        #expect(LocalUsageText.costHelp(partial).contains("Known subtotal"))
        #expect(LocalUsageText.costHelp(partial).contains("Prices cover 50%"))
        #expect(LocalUsageText.costHelp(.init(tokens: 1, estimatedUSD: 1.234567890123, partial: false))
            .contains("≈$1.234567890123 USD"))
        #expect(LocalUsageText.costHelp(.init(tokens: 1, estimatedUSD: 1e-12, partial: false))
            .contains("≈$1e-12 USD"))
        #expect(LocalUsageText.cost(.init(tokens: 110, estimatedUSD: nil, partial: false)) == "Cost unavailable")
        #expect(LocalUsageText.cost(nil) == "Cost unavailable")
    }
    // AC-04.02, AC-04.03, AC-04.08: coverage is separate from token/history completeness.
    @Test func partialPricesHaveCompactBarLabelsAndExplainedKnownSubtotals() {
        let mixed = LocalUsageAmount(tokens: 220, estimatedUSD: 0.0003, partial: false,
                                     pricedTokens: 110, unpricedTokens: 110)
        #expect(LocalUsageText.tokens(mixed) == "220 tokens")
        #expect(LocalUsageText.cost(mixed) == "≥$0.0003")
        #expect(LocalUsageText.costHelp(mixed).contains("Known subtotal"))
        #expect(LocalUsageText.coverage([mixed]) == "Prices cover 50% of recorded tokens.")
        #expect(LocalUsageText.coverage([]) == "Price coverage unavailable.")
        #expect(LocalUsageText.costBar(mixed) == "≥$0.0003")
        #expect(LocalUsageText.costBar(.init(tokens: nil, estimatedUSD: nil, partial: false)) == "—")
        #expect(LocalUsageText.costBar(.init(tokens: 1, estimatedUSD: 0.00000001, partial: false)) == "≈$1e-08")
        #expect(LocalUsageText.costBar(.init(tokens: 1, estimatedUSD: 1234.56, partial: false)) == "≈$1.2K")
        for value in [0, 0.1, 99.99, 999.99, 9999, 999999, 1e9, 1e12, 1e15] {
            let label = LocalUsageText.costBar(.init(tokens: 1, estimatedUSD: value, partial: true))
            #expect(label.count <= 9)
            let width = (label as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)]).width
            #expect(width <= 50.4) // 320-point chart minus 28 padding and four 10-point gaps, divided by five.
            #expect(!label.contains("…") && !label.contains("US$"))
        }
    }
    // AC-04.08: partial price coverage and its explanation fit the existing native popup.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
    func costChartFitsTheNativePopupWithPartialPriceCoverage() async throws {
        _ = NSApplication.shared
        let amount = LocalUsageAmount(tokens: 220, estimatedUSD: 999999.12345678, partial: false,
                                     pricedTokens: 110, unpricedTokens: 110)
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_793_016_000))
        let days = (-4...0).map { LocalUsageDay(date: Calendar.current.date(byAdding: .day, value: $0, to: today)!, amount: amount) }
        let model = LocalUsageModel(reader: HistoryReader(history: .init(days: days, sessions: [:], partial: false)))
        model.refresh()
        try await settle(model)
        let hosting = NSHostingView(rootView: UsageHistoryPanel(model: model, showCost: true).frame(width: 320))
        hosting.frame = .init(x: 0, y: 0, width: 320, height: 280)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height <= 280)
        await model.shutdown()
    }
    private func settle(_ model: LocalUsageModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isLoading)
    }
}
