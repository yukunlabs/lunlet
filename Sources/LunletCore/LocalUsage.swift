// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.02, AC-04.03, AC-04.05, AC-04.08, AC-04.11.
// Refs: US-18, AC-18.01, AC-18.02, AC-18.03; US-32, AC-32.01, AC-32.03, AC-32.04; US-33, AC-33.10.
import Foundation

/// Recorded token categories, for providers whose records separate them. Cache writes include every duration.
public struct LocalTokenBreakdown: Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64
    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

/// Read-only accounting on this Mac. These values never establish session liveness or input authority.
public struct LocalUsageAmount: Equatable, Sendable {
    public let tokens: Int64?
    public let estimatedUSD: Double?
    /// Incomplete token history, independently of missing model prices.
    public let partial: Bool
    public let pricedTokens: Int64
    public let unpricedTokens: Int64
    /// Nil when the source records only totals, as Codex does; never inferred from a total.
    public let breakdown: LocalTokenBreakdown?
    public var costPartial: Bool { partial || unpricedTokens > 0 }
    public init(tokens: Int64?, estimatedUSD: Double?, partial: Bool,
                pricedTokens: Int64? = nil, unpricedTokens: Int64? = nil, breakdown: LocalTokenBreakdown? = nil) {
        self.tokens = tokens; self.estimatedUSD = estimatedUSD; self.partial = partial; self.breakdown = breakdown
        self.pricedTokens = pricedTokens ?? (estimatedUSD == nil ? 0 : tokens ?? 0)
        self.unpricedTokens = unpricedTokens ?? (estimatedUSD == nil ? tokens ?? 0 : 0)
    }
}

public struct LocalUsageDay: Equatable, Sendable, Identifiable {
    public let date: Date
    public let amount: LocalUsageAmount
    public var id: Date { date }
    public init(date: Date, amount: LocalUsageAmount) { self.date = date; self.amount = amount }
}

public struct LocalUsageHistory: Equatable, Sendable {
    public let days: [LocalUsageDay]
    public let sessions: [UUID: LocalUsageAmount]
    public let partial: Bool
    public let quotaHistory: [LocalQuotaObservation]
    public init(days: [LocalUsageDay], sessions: [UUID: LocalUsageAmount], partial: Bool, quotaHistory: [LocalQuotaObservation] = []) {
        self.days = days; self.sessions = sessions; self.partial = partial; self.quotaHistory = quotaHistory
    }
}

/// Local rollout quota metadata has no verified account identity.
public struct LocalQuotaObservation: Equatable, Hashable, Sendable {
    public let at: Date
    public let resetAt: Date
    public let remaining: Double
    public let bucketID: String
    public let plan: String?
    public init(at: Date, resetAt: Date, remaining: Double, bucketID: String, plan: String?) {
        self.at = at; self.resetAt = resetAt; self.remaining = remaining; self.bucketID = bucketID; self.plan = plan
    }
}

public protocol LocalUsageReading: Sendable {
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory
}

public extension LocalUsageReading {
    func readHistory(now: Date, calendar: Calendar) async throws -> LocalUsageHistory {
        try await readHistory(now: now, calendar: calendar, days: 5)
    }
}

public enum LocalUsageReadFailure: Error, Sendable { case unavailable, invalidRange }
