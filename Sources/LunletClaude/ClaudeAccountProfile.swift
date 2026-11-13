// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.11; US-04, AC-04.03, AC-04.09; US-25, AC-25.01.
import Darwin
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
    public static func read(home: ClaudeHome) -> ClaudeAccountProfile? { read(home: home, load: load) }

    /// `load` is the bounded read of the whole file, replaceable so a test can count it. The file is megabytes of
    /// which two fields matter, and the limits are refreshed several times a second while the panel is open, so the
    /// result is remembered for the file as it stands (its identity, size and modification time) and the file is
    /// read again only when one of those changed. Only the two fields are remembered, as before.
    static func read(home: ClaudeHome, load: (URL) -> Data?) -> ClaudeAccountProfile? {
        let url = home.profile
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            remembered.withLock { $0[url.path] = nil }
            return nil
        }
        let stamp = Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                          seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        if let known = remembered.withLock({ $0[url.path] }), known.stamp == stamp { return known.profile }
        let profile = load(url).flatMap(decode)
        remembered.withLock { $0[url.path] = (stamp, profile) }
        return profile
    }
    private struct Stamp: Equatable { let device: Int32; let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int }
    private static let remembered = Remembered()
    private final class Remembered: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (stamp: Stamp, profile: ClaudeAccountProfile?)] = [:]
        func withLock<Value>(_ body: (inout [String: (stamp: Stamp, profile: ClaudeAccountProfile?)]) -> Value) -> Value {
            lock.lock(); defer { lock.unlock() }
            return body(&values)
        }
    }

    static func load(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return data
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
