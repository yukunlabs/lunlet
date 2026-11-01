// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.04, AC-33.07, AC-33.08.
import Foundation

/// Claude Code's local configuration root. Only Lunlet's own environment may relocate it;
/// the environments of Claude processes are never read.
public struct ClaudeHome: Equatable, Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            if path.hasPrefix("/") { return .init(root: URL(fileURLWithPath: path, isDirectory: true)) }
        }
        return .init(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true))
    }

    /// Per-process session records written by Claude Code itself.
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    /// Transcripts grouped by project directory.
    var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    /// User settings; Lunlet edits only its `statusLine` member, and only after an explicit connect action.
    public var settings: URL { root.appendingPathComponent("settings.json", isDirectory: false) }
    /// Claude Code's own configuration file with the cached account: beside the default root in the home folder, or
    /// inside a relocated root.
    public var profile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return root == home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
            ? home.appendingPathComponent(".claude.json", isDirectory: false)
            : root.appendingPathComponent(".claude.json", isDirectory: false)
    }
}
