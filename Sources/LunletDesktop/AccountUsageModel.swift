// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.03, AC-32.07.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05, AC-04.06; US-12, AC-12.04.
import Combine
import Foundation
import LunletCore
import LunletCodex

@MainActor final class AccountUsageModel: ObservableObject {
    enum State: Equatable {
        case disabled, loading, stopping, unavailable
        case available(AccountLimitsSnapshot)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var weeklyTrend = WeeklyQuotaTrend()
    /// A failed read keeps the trend built from earlier successful reads; the panel labels it stale.
    @Published private(set) var latestReadFailed = false
    private var lastAvailable: AccountLimitsSnapshot?
    var displayedSnapshot: AccountLimitsSnapshot? {
        switch state {
        case .available(let snapshot): return snapshot
        case .loading: return lastAvailable
        default: return nil
        }
    }
    private let client: any CodexAccountReading
    private let now: @MainActor () -> ContinuousClock.Instant
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var closed = false
    private var lastAttempt: ContinuousClock.Instant?

    init(client: any CodexAccountReading = CodexAccountClient(),
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.client = client
        self.now = now
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        refresh()
    }

    // Panel openings retry at most once per five minutes, including failed reads.
    // There is no polling timer; a monotonic clock avoids wall-clock adjustments.
    func refreshIfNeeded() {
        guard lastAttempt.map({ now() - $0 >= .seconds(300) }) ?? true else { return }
        refresh()
    }

    // The global Refresh action can refresh sooner, but never starts concurrent clients.
    func refresh() {
        guard started, !closed, operation == nil else { return }
        let current = UUID()
        generation = current
        lastAttempt = now()
        state = .loading
        operation = Task {
            defer { if generation == current { operation = nil } }
            do {
                let snapshot = try await client.readLimits()
                try Task.checkCancellation()
                guard generation == current, !closed else { return }
                weeklyTrend.record(snapshot)
                latestReadFailed = false
                lastAvailable = snapshot
                state = .available(snapshot)
            } catch {
                guard generation == current, !closed, !Task.isCancelled else { return }
                latestReadFailed = true
                state = .unavailable
            }
        }
    }

    func shutdown() async {
        if closed { await operation?.value; return }
        closed = true
        generation = UUID()
        state = .stopping
        operation?.cancel()
        await operation?.value
        operation = nil
        state = .disabled; lastAvailable = nil; weeklyTrend = WeeklyQuotaTrend(); latestReadFailed = false
    }
}
