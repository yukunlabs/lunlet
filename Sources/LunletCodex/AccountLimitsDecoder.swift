// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.06, AC-04.09.
import Foundation
import LunletCore

public enum AccountLimitsError: Error, Equatable { case invalidResponse }

/// Decodes the Codex account interface's quota and identity responses.
public enum AccountLimitsDecoder {
    public static func decode(_ data: Data, observedAt: Date, accountData: Data? = nil) throws -> AccountLimitsSnapshot {
        guard data.count <= 65_536, observedAt.timeIntervalSince1970.isFinite else {
            throw AccountLimitsError.invalidResponse
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let buckets: [QuotaBucket]
            if let multiple = response.rateLimitsByLimitId, !multiple.isEmpty {
                buckets = try multiple.keys.sorted().map { key in
                    guard !key.isEmpty, let value = multiple[key],
                          value.limitId == nil || value.limitId == key else {
                        throw AccountLimitsError.invalidResponse
                    }
                    return value.bucket(id: key)
                }
            } else {
                buckets = response.rateLimits.map { [$0.bucket(id: nonempty($0.limitId))] } ?? []
            }
            let resets = try response.rateLimitResetCredits.map { value in
                let details = try value.credits.map { rows in
                    try rows.map { row in
                        guard !row.id.isEmpty else { throw AccountLimitsError.invalidResponse }
                        return ResetEntitlement(id: row.id, status: nonempty(row.status),
                                                resetType: nonempty(row.resetType), expiresAt: date(row.expiresAt))
                    }
                }
                return EarnedResets(availableCount: value.availableCount.flatMap { $0 >= 0 ? $0 : nil }, details: details)
            }
            var snapshot = AccountLimitsSnapshot(buckets: buckets, earnedResets: resets, observedAt: observedAt)
            if let accountData, accountData.count <= 65_536,
               let account = try? JSONDecoder().decode(IdentityResponse.self, from: accountData).account,
               account.type == "chatgpt" {
                snapshot.identity = AccountIdentity(email: displayText(account.email), plan: displayText(account.planType))
            }
            return snapshot
        } catch {
            throw AccountLimitsError.invalidResponse
        }
    }

    private struct Response: Decodable {
        let rateLimits: RawBucket?
        let rateLimitsByLimitId: [String: RawBucket]?
        let rateLimitResetCredits: RawResets?
    }

    private struct IdentityResponse: Decodable { let account: RawIdentity? }
    private struct RawIdentity: Decodable { let type: String; let email: String?; let planType: String? }
    private struct RawCredits: Decodable {
        let balance: String?
        let hasCredits: Bool?
        let unlimited: Bool?
        var value: AccountCredits {
            let number = balance.flatMap { Double($0) }
            let valid = number.map { $0.isFinite && $0 >= 0 } ?? false
            return AccountCredits(balance: valid ? balance : nil, hasCredits: hasCredits, unlimited: unlimited)
        }
    }
    private static func displayText(_ text: String?) -> String? {
        guard let text = nonempty(text), text.count <= 254,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    private struct RawBucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: RawWindow?
        let secondary: RawWindow?
        let credits: RawCredits?

        func bucket(id: String?) -> QuotaBucket {
            QuotaBucket(id: id, name: nonempty(limitName), primary: primary?.window, secondary: secondary?.window, credits: credits?.value)
        }
    }

    private struct RawWindow: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Int?

        var window: QuotaWindow {
            QuotaWindow(usedPercent: usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        durationMinutes: windowDurationMins.flatMap { $0 > 0 ? $0 : nil }, resetsAt: date(resetsAt))
        }
    }

    private struct RawResets: Decodable {
        let availableCount: Int?
        let credits: [RawReset]?
    }

    private struct RawReset: Decodable {
        let id: String
        let status: String?
        let resetType: String?
        let expiresAt: Int?
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func date(_ seconds: Int?) -> Date? {
        guard let seconds, seconds > 0, seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
