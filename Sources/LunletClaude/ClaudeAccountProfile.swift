// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.11; US-04, AC-04.03, AC-04.09.
import Foundation

/// The signed-in account as Claude Code caches it in its own configuration file: only the email and the plan are
/// kept, in memory. No credential is read, nothing is sent anywhere and no value is logged. An unrecognized plan stays nil rather than a guess.
public struct ClaudeAccountProfile: Equatable, Sendable {
    public let email: String?
    public let plan: String?
    public init(email: String?, plan: String?) { self.email = email; self.plan = plan }

    /// Claude Code's configuration file holds far more than the account, such as project history, so it is parsed
    /// once with a size limit and everything but two fields of `oauthAccount` is discarded.
    public static let maximumBytes = 32 << 20

    /// Nil when the file is missing, unreadable, oversized or has no account.
    public static func read(home: ClaudeHome) -> ClaudeAccountProfile? {
        guard let handle = try? FileHandle(forReadingFrom: home.profile) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> ClaudeAccountProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        let email = (account["emailAddress"] as? String).flatMap { $0.contains("@") && $0.count <= 320 ? $0 : nil }
        let profile = ClaudeAccountProfile(email: email, plan: plan(organizationType: account["organizationType"] as? String,
                                                                    rateLimitTier: account["organizationRateLimitTier"] as? String))
        return profile.email == nil && profile.plan == nil ? nil : profile
    }

    /// Plan names from the known values only.
    static func plan(organizationType: String?, rateLimitTier: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        switch organizationType?.lowercased() {
        case "claude_max": return tier.hasSuffix("max_20x") ? "Max 20x" : tier.hasSuffix("max_5x") ? "Max 5x" : "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }
}
