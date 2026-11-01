// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.06, AC-04.09; US-33, AC-33.09; US-19, AC-19.04.
import Foundation

/// One provider-reported rate-limit window in the provider's own percent-used terms: an official value, not an estimate.
/// Windows of different providers are never combined (AC-19.04).
public struct LimitWindowReading: Equatable, Sendable {
    /// Percent of the window used, 0...100.
    public let usedPercent: Double
    public let resetsAt: Date
    /// When this value was last observed.
    public let at: Date
    public init(usedPercent: Double, resetsAt: Date, at: Date) {
        self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.at = at
    }
    /// The same reading as remaining allowance, for the provider-independent pace estimator.
    public var remaining: QuotaReading { .init(at: at, remaining: 100 - usedPercent, resetAt: resetsAt) }
}

public struct QuotaWindow: Equatable, Sendable {
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var estimatedRemainingPercent: Double? { usedPercent.map { max(0, 100 - $0) } }
    public init(usedPercent: Double?, durationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
}

public struct QuotaBucket: Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public var credits: AccountCredits? = nil
    public init(id: String?, name: String?, primary: QuotaWindow?, secondary: QuotaWindow?, credits: AccountCredits? = nil) {
        self.id = id; self.name = name; self.primary = primary; self.secondary = secondary; self.credits = credits
    }
}

public struct ResetEntitlement: Equatable, Sendable {
    public let id: String
    public let status: String?
    public let resetType: String?
    public let expiresAt: Date?
    public init(id: String, status: String?, resetType: String?, expiresAt: Date?) {
        self.id = id; self.status = status; self.resetType = resetType; self.expiresAt = expiresAt
    }
}

public struct EarnedResets: Equatable, Sendable {
    public enum DetailCoverage: Equatable, Sendable { case complete, partial, unknown }
    public let availableCount: Int?
    public let details: [ResetEntitlement]?
    public init(availableCount: Int?, details: [ResetEntitlement]?) { self.availableCount = availableCount; self.details = details }
    public var detailCoverage: DetailCoverage {
        guard let availableCount, let details else { return .unknown }
        let identifiers = Set(details.filter { $0.status == "available" }.map(\.id))
        return identifiers.count == availableCount ? .complete : .partial
    }
}

public struct AccountLimitsSnapshot: Equatable, Sendable {
    public let buckets: [QuotaBucket]
    public let earnedResets: EarnedResets?
    public let observedAt: Date
    public var identity: AccountIdentity? = nil
    public init(buckets: [QuotaBucket], earnedResets: EarnedResets?, observedAt: Date, identity: AccountIdentity? = nil) {
        self.buckets = buckets; self.earnedResets = earnedResets; self.observedAt = observedAt; self.identity = identity
    }
}
