// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.03, AC-38.04, AC-38.05; US-10, AC-10.01, AC-10.03; US-25, AC-25.01.
import CryptoKit
import Darwin
import Foundation
import LunletHook

/// A hook record in a Claude transcript: the `stop_hook_summary` Claude Code writes after its Stop hooks ran,
/// whose `hookAdditionalContext` carries the follow-up Lunlet's hook handed over.
enum ClaudeHookRecord {
    /// The follow-up texts Lunlet's hook handed to this turn end, in order; empty for any other record.
    static func followups(in object: [String: Any]) -> [String] {
        guard object["type"] as? String == "system", object["subtype"] as? String == "stop_hook_summary",
              let contexts = object["hookAdditionalContext"] as? [Any] else { return [] }
        return contexts.compactMap { ($0 as? String).flatMap(HookOutput.followup(in:)) }
    }
}

/// Confirms delivery from the session's own transcript rather than from the helper's receipt: the first Lunlet
/// hook record appended after the watch began must carry the reply. Only a digest of the normalized reply is
/// retained, reads are bounded, and the file's identity is rechecked on every poll.
struct ClaudeDeliveryWatch {
    enum Status: Equatable {
        case pending
        case delivered
        /// Another Lunlet follow-up came first; the reply's arrival cannot be attributed.
        case mismatched
        /// The transcript was replaced, truncated, unreadable or exceeded the read budget.
        case unavailable
    }

    private static let maximumLine = 2_097_152
    private let file: ClaudeTranscriptFile
    private let expected: SHA256.Digest
    private var offset: UInt64
    private var pending = Data()
    private var budget = 4_194_304

    /// Starts at the transcript's current end, before the reply is handed to the helper.
    init?(file: ClaudeTranscriptFile, text: String) {
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode,
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { return nil }
        self.file = file
        offset = UInt64(status.st_size)
        expected = Self.digest(text)
    }

    mutating func poll() -> Status {
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode,
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0, UInt64(status.st_size) >= offset else { return .unavailable }
        let size = UInt64(status.st_size)
        guard size > offset else { return .pending }
        do { try handle.seek(toOffset: offset) } catch { return .unavailable }
        while offset < size {
            guard budget > 0 else { return .unavailable }
            // Each chunk and each decoded record is released as it goes, not when the poll's job ends (AC-25.01).
            // Nil goes on to the next chunk; a status ends the poll.
            let outcome = autoreleasepool { () -> Status? in
                let count = min(65_536, budget, Int(size - offset))
                guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { return .pending }
                offset += UInt64(chunk.count); budget -= chunk.count
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard line.count <= Self.maximumLine else { continue }
                    switch Self.inspect(line, expected: expected) {
                    case .delivered: return .delivered
                    case .mismatched: return .mismatched
                    case .pending, .unavailable: continue
                    }
                }
                return pending.count <= Self.maximumLine ? nil : .unavailable
            }
            if let outcome { return outcome }
        }
        return .pending
    }

    private static func inspect(_ line: Data, expected: SHA256.Digest) -> Status {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let first = ClaudeHookRecord.followups(in: object).first else { return .pending }
        return digest(first) == expected ? .delivered : .mismatched
    }
    static func digest(_ text: String) -> SHA256.Digest {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
}
