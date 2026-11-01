// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.04; US-10, AC-10.01, AC-10.03.
import CryptoKit
import Darwin
import Foundation
import LunletCore

/// Confirms delivery from the session's own record rather than from queue acceptance: the first
/// developer message appended after the watch began must carry the reply. Only a digest of the
/// normalized reply is retained, and reads are bounded.
struct CodexDeliveryWatch {
    enum Status: Equatable {
        /// No developer message has been appended yet.
        case pending
        /// The first appended developer message is the reply.
        case delivered
        /// Another developer message came first; the reply's arrival cannot be attributed.
        case mismatched
        /// The record was replaced, truncated, unreadable or exceeded the read budget.
        case unavailable
    }

    private static let maximumLine = 2_097_152
    private let file: CodexRolloutFile
    private let expected: SHA256.Digest
    private var offset: UInt64
    private var pending = Data()
    private var budget = 4_194_304

    /// Starts at the record's current end, before the reply is handed to the CLI.
    init?(file: CodexRolloutFile, text: String) {
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
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0,
              UInt64(status.st_size) >= offset else { return .unavailable }
        let size = UInt64(status.st_size)
        guard size > offset else { return .pending }
        do { try handle.seek(toOffset: offset) } catch { return .unavailable }
        while offset < size {
            guard budget > 0 else { return .unavailable }
            let count = min(65_536, budget, Int(size - offset))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            budget -= chunk.count
            if let decided = consume(chunk) { return decided }
        }
        return .pending
    }

    private mutating func consume(_ chunk: Data) -> Status? {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            let end = chunk[cursor...].firstIndex(of: 10) ?? chunk.endIndex
            // An oversized record cannot be ruled out as a developer message.
            guard pending.count + (end - cursor) <= Self.maximumLine else { return .unavailable }
            pending.append(chunk[cursor..<end])
            if end < chunk.endIndex {
                let line = pending
                pending.removeAll(keepingCapacity: true)
                if let decided = Self.classify(line, expected: expected) { return decided }
            }
            cursor = end < chunk.endIndex ? end + 1 : end
        }
        return nil
    }

    /// Nil for records that are not developer messages, including hidden runtime context.
    static func classify(_ line: Data, expected: SHA256.Digest) -> Status? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        let text: String
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "user" else { return nil }
            let parts = payload["content"] as? [[String: Any]] ?? []
            let texts = parts.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
            if texts.contains(where: { CodexSessionReader.isContextualFragment($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                return nil
            }
            text = texts.joined(separator: " ")
        case ("event_msg", "user_message"):
            guard let message = payload["message"] as? String else { return .mismatched }
            if CodexSessionReader.isContextualFragment(message.trimmingCharacters(in: .whitespacesAndNewlines)) { return nil }
            text = message
        default:
            return nil
        }
        return digest(text) == expected ? .delivered : .mismatched
    }

    private static func digest(_ text: String) -> SHA256.Digest {
        SHA256.hash(data: Data(ContinuationText.normalized(text).utf8))
    }
}
