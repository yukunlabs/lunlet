// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.06, AC-04.09.
import Foundation
import Testing
import LunletCore
@testable import LunletCodex

private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

@Test func officialQuotaWindowsRetainTheirValuesAndObservationTime() throws {
    let data = Data(#"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800001000},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1800002000}}}"#.utf8)
    let result = try AccountLimitsDecoder.decode(data, observedAt: observedAt)
    let bucket = try #require(result.buckets.first)
    #expect(bucket.id == "codex")
    #expect(bucket.primary?.usedPercent == 25)
    #expect(bucket.primary?.durationMinutes == 300)
    #expect(bucket.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_001_000))
    #expect(bucket.secondary?.usedPercent == 80)
    #expect(result.observedAt == observedAt)
}

@Test func aMultiBucketResponseReplacesTheLegacySingleBucketView() throws {
    let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25}},"model-special":{"limitName":"Special model","primary":{"usedPercent":60}}}}"#.utf8)
    let result = try AccountLimitsDecoder.decode(data, observedAt: observedAt)
    #expect(result.buckets.map(\.id) == ["codex", "model-special"])
    #expect(result.buckets.map { $0.primary?.usedPercent } == [25, 60])
    #expect(result.buckets.last?.name == "Special model")
}

@Test func unknownQuotaFieldsStayUnknownInsteadOfBecomingZero() throws {
    let data = Data(#"{"rateLimits":{"limitId":null,"primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null},"secondary":null},"rateLimitResetCredits":null}"#.utf8)
    let result = try AccountLimitsDecoder.decode(data, observedAt: observedAt)
    let bucket = try #require(result.buckets.first)
    #expect(bucket.id == nil)
    #expect(bucket.primary?.usedPercent == nil)
    #expect(bucket.primary?.resetsAt == nil)
    #expect(bucket.secondary == nil)
    #expect(result.earnedResets == nil)
}

@Test func earnedResetCountDoesNotComeFromPartialDetailRows() throws {
    let data = Data(#"{"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"synthetic-reset","resetType":"codexRateLimits","status":"available","grantedAt":1800000000,"expiresAt":1800002000,"title":null,"description":null}]}}"#.utf8)
    let result = try AccountLimitsDecoder.decode(data, observedAt: observedAt)
    #expect(result.buckets.isEmpty)
    #expect(result.earnedResets?.availableCount == 3)
    #expect(result.earnedResets?.details?.count == 1)
    #expect(result.earnedResets?.details?.first?.status == "available")
    #expect(result.earnedResets?.details?.first?.resetType == "codexRateLimits")
    #expect(result.earnedResets?.detailCoverage == .partial)
    #expect(result.earnedResets?.details?.first?.expiresAt == Date(timeIntervalSince1970: 1_800_002_000))
}

@Test func missingResetDetailsAndConfirmedEmptyDetailsRemainDistinct() throws {
    let countOnly = try AccountLimitsDecoder.decode(Data(#"{"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#.utf8), observedAt: observedAt)
    let empty = try AccountLimitsDecoder.decode(Data(#"{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#.utf8), observedAt: observedAt)
    #expect(countOnly.earnedResets?.availableCount == 2)
    #expect(countOnly.earnedResets?.details == nil)
    #expect(countOnly.earnedResets?.detailCoverage == .unknown)
    #expect(empty.earnedResets?.availableCount == 0)
    #expect(empty.earnedResets?.details == [])
    #expect(empty.earnedResets?.detailCoverage == .complete)
}

@Test func malformedAndMismatchedQuotaResponsesCannotProduceKnownLimits() {
    for value in [#"{"rateLimits":{"primary":{"usedPercent":"unknown"}}}"#,
                  #"{"rateLimitsByLimitId":{"codex":{"limitId":"different-account-bucket"}}}"#] {
        #expect(throws: AccountLimitsError.invalidResponse) {
            try AccountLimitsDecoder.decode(Data(value.utf8), observedAt: observedAt)
        }
    }
}

@Test func remainingAllowanceIsDerivedOnlyFromReportedUsageAndCannotGoNegative() throws {
    for (used, remaining) in [(25, 75.0), (101, 0.0)] {
        let data = Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(used)}}}".utf8)
        let snapshot = try AccountLimitsDecoder.decode(data, observedAt: observedAt)
        #expect(snapshot.buckets.first?.primary?.estimatedRemainingPercent == remaining)
    }
    let unknown = try AccountLimitsDecoder.decode(Data(#"{"rateLimits":{"primary":{}}}"#.utf8), observedAt: observedAt)
    #expect(unknown.buckets.first?.primary?.estimatedRemainingPercent == nil)
}

@Test func accountIdentityAndCreditBalanceDoNotInventMultipliersOrCurrency() throws {
    let result = try AccountLimitsDecoder.decode(
        Data(#"{"rateLimits":{"limitId":"codex","credits":{"balance":"17.25","hasCredits":true,"unlimited":false}}}"#.utf8),
        observedAt: observedAt,
        accountData: Data(#"{"account":{"type":"chatgpt","email":"developer@example.invalid","planType":"pro"}}"#.utf8))
    #expect(result.identity?.email == "developer@example.invalid")
    #expect(result.identity?.plan == "pro")
    #expect(result.buckets.first?.credits?.balance == "17.25")
    #expect(result.buckets.first?.credits?.unlimited == false)
    #expect(result.earnedResets == nil)
}

@Test func unknownIdentityAndMalformedCreditsStayUnavailable() throws {
    let result = try AccountLimitsDecoder.decode(
        Data(#"{"rateLimits":{"credits":{"balance":"not-a-number","hasCredits":true,"unlimited":true}}}"#.utf8),
        observedAt: observedAt, accountData: Data(#"{"account":{"type":"apiKey"}}"#.utf8))
    #expect(result.identity == nil)
    #expect(result.buckets.first?.credits?.balance == nil)
    #expect(result.buckets.first?.credits?.unlimited == true)
}
