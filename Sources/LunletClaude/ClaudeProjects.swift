// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.04, AC-33.06, AC-33.07.
import Darwin
import Foundation

/// A transcript identified by file identity; `url` is its current path.
struct ClaudeTranscriptFile: Hashable, Sendable {
    let url: URL
    let device: Int32
    let inode: UInt64
    static func == (left: Self, right: Self) -> Bool { left.device == right.device && left.inode == right.inode }
    func hash(into hasher: inout Hasher) { hasher.combine(device); hasher.combine(inode) }
}

/// Bounded lookups under `projects/`. Only `<session>.jsonl` and `<session>/subagents/agent-*.jsonl`
/// are ever named; tool-result, memory and other files are never listed into or opened.
enum ClaudeProjects {
    static let maximumDirectories = 4_096
    /// Claude truncates longer encoded names and appends a hash; those need the bounded scan.
    static let maximumEncodedName = 200

    /// Claude names a project directory by replacing every non-alphanumeric UTF-16 unit of the cwd with "-".
    static func encodedDirectoryName(_ cwd: String) -> String {
        String(cwd.utf16.map { unit -> Character in
            if let scalar = Unicode.Scalar(unit), scalar.isASCII,
               CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        })
    }

    /// The encoded-cwd directory first, then a bounded scan of project directories for the exact file name.
    static func transcript(sessionName: String, cwd: String?, projects: URL) -> ClaudeTranscriptFile? {
        let fileName = sessionName + ".jsonl"
        if let cwd {
            let encoded = encodedDirectoryName(cwd)
            if encoded.utf8.count <= maximumEncodedName {
                let directory = projects.appendingPathComponent(encoded, isDirectory: true)
                if let file = regularFile(directory.appendingPathComponent(fileName)) { return file }
                // A short name is exact: an existing directory without the file means it is not written yet.
                if isDirectory(directory) { return nil }
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for name in names.sorted().prefix(maximumDirectories) where !name.hasPrefix(".") {
            let candidate = projects.appendingPathComponent(name, isDirectory: true).appendingPathComponent(fileName)
            if let file = regularFile(candidate) { return file }
        }
        return nil
    }

    /// A current-user regular file reached without following a final symbolic link.
    static func regularFile(_ url: URL) -> ClaudeTranscriptFile? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        return .init(url: url, device: info.st_dev, inode: info.st_ino)
    }
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
    static func isSessionName(_ name: String) -> Bool { name.utf8.count == 36 && UUID(uuidString: name) != nil }
}
