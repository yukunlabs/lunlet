// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.06, AC-33.07.
// Refs: US-13, AC-13.01, AC-13.04; US-15, AC-15.02, AC-15.06; US-06, AC-06.02, AC-06.05; US-33, AC-33.05.
import Darwin
import Foundation
import LunletCore

struct ClaudeTranscriptContent: Equatable, Sendable {
    var phase: SessionPhase = .unknown
    var turn: String?
    var outcome: TaskCue.Outcome = .unknown
    var inputActivityID: String?
    var localPreview: String?
    /// The text of the final reply of the latest completed turn, for the owner's completion notice.
    var conclusion: String?

    /// Unconfirmed state keeps identity and input evidence but no conclusion or outcome.
    func unconfirmed() -> Self {
        var next = self
        next.phase = .unknown; next.outcome = .unknown; next.conclusion = nil
        return next
    }
}
struct ClaudeTranscriptRead: Sendable {
    let content: ClaudeTranscriptContent
    let baseline: Bool
    let needsCatchup: Bool
    let lastActivityAt: Date?
}
enum ClaudeTranscriptFailure: Error { case unavailable, invalidIdentity }

/// Bounded incremental observation of one main transcript. It decodes each record transiently and keeps
/// only turn, input and timing metadata, the bounded local preview and the text blocks of the reply that
/// ends a turn; thinking, tool use and tool results are never kept. It never establishes input authority.
struct ClaudeTranscriptReader {
    /// Record types observed in Claude Code 2.1.306–2.1.314 that carry no turn state.
    static let ignoredTypes: Set<String> = ["last-prompt", "mode", "permission-mode", "attachment", "file-history-snapshot",
        "file-history-delta", "api-request-shape", "api-request-blob", "api-request", "atis-latch", "cost-state",
        "tools-used", "queue-operation", "ai-title"]
    static let promptSources: Set<String> = ["typed", "queued", "suggestion_accepted"]
    static let maximumLine = 2_097_152
    static let maximumRead = 4_194_304

    let file: ClaudeTranscriptFile
    let sessionName: String
    private var offset: UInt64 = 0
    private var pending = Data()
    private var droppingLine = false
    private var content: ClaudeTranscriptContent?
    private var endTurnSeen = false
    /// Claude writes one record per content block, so a reply's text is gathered by message ID.
    private var replyMessageID: String?
    private var replyRecords = Set<String>()
    private var replyText = ""
    private var endTurnReply: String?
    private var lastActivityAt: Date?
    private var recovering = false

    init(file: ClaudeTranscriptFile, sessionName: String) { self.file = file; self.sessionName = sessionName }

    mutating func read() throws -> ClaudeTranscriptRead {
        try Task.checkCancellation()
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ClaudeTranscriptFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode,
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw ClaudeTranscriptFailure.invalidIdentity }
        let size = UInt64(status.st_size)
        let resetting = content == nil || size < offset
        let baseline = resetting || recovering
        if resetting {
            content = .init(); endTurnSeen = false; lastActivityAt = nil; pending.removeAll(); droppingLine = false
            resetReply()
            // Initial state comes from the latest bounded tail; a partial first line is skipped.
            offset = size > UInt64(Self.maximumRead) ? size - UInt64(Self.maximumRead) : 0
            droppingLine = offset > 0
        }
        try handle.seek(toOffset: offset)
        var budget = Self.maximumRead
        while budget > 0, offset < size {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, budget, Int(size - offset))) ?? Data()
            guard !chunk.isEmpty else { break }
            offset += UInt64(chunk.count); budget -= chunk.count
            consume(chunk)
        }
        guard let content else { throw ClaudeTranscriptFailure.invalidIdentity }
        let needsCatchup = offset < size
        recovering = needsCatchup
        return .init(content: needsCatchup ? content.unconfirmed() : content, baseline: baseline || needsCatchup,
                     needsCatchup: needsCatchup, lastActivityAt: needsCatchup ? nil : lastActivityAt)
    }

    /// Lines over the bound are dropped; they make state unknown, never a read failure.
    private mutating func consume(_ chunk: Data) {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            let end = chunk[cursor...].firstIndex(of: 10) ?? chunk.endIndex
            if !droppingLine {
                if pending.count + end - cursor > Self.maximumLine {
                    pending.removeAll(keepingCapacity: true); droppingLine = true; unconfirm()
                } else { pending.append(chunk[cursor..<end]) }
            }
            if end < chunk.endIndex {
                if !droppingLine, !pending.isEmpty { consumeLine(pending) }
                pending.removeAll(keepingCapacity: true); droppingLine = false
            }
            cursor = end < chunk.endIndex ? end + 1 : end
        }
    }
    /// A dropped or unreadable line may have held part of the reply, so the gathered text is discarded.
    private mutating func unconfirm() { content = content?.unconfirmed(); resetReply() }
    private mutating func resetReply() { replyMessageID = nil; replyRecords = []; replyText = ""; endTurnReply = nil }

    /// Gathers the `text` blocks of one assistant message across its records, bounded and once per record.
    private mutating func gatherReply(_ message: [String: Any], record: String?) {
        guard let parts = message["content"] as? [[String: Any]] else { return }
        let id = Self.identifier(message["id"])
        if id == nil || id != replyMessageID { replyMessageID = id; replyRecords = []; replyText = "" }
        let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return }
        let text = texts.joined(separator: "\n\n")
        guard replyRecords.count < 256, replyRecords.insert(record ?? String(text.hashValue)).inserted else { return }
        replyText = NoticeText.prefix(replyText.isEmpty ? text : replyText + "\n\n" + text, utf8Limit: NoticeText.captureLimit)
    }

    private mutating func consumeLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, let old = content else { unconfirm(); return }
        // Only an accepted state change affects History recency; writes, ignored and unknown records never do.
        defer {
            if content != old, content?.phase != .unknown {
                if let raw = object["timestamp"] as? String, raw.utf8.count <= 64,
                   let date = ClaudeTimestamps.shared.date(from: raw) {
                    lastActivityAt = max(lastActivityAt ?? date, date)
                } else { lastActivityAt = nil }
            }
        }
        if let version = object["version"] as? String, !Self.supportsVersion(version) { unconfirm(); return }
        // Copied or foreign records never describe this session's live turn.
        if let session = object["sessionId"] as? String, session.lowercased() != sessionName { return }
        if object["isSidechain"] as? Bool == true { return }
        switch type {
        case "user": consumeUser(object)
        case "assistant":
            guard let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            gatherReply(message, record: Self.identifier(object["uuid"]))
            guard let stop = message["stop_reason"] as? String else { return }
            endTurnSeen = stop == "end_turn"
            if endTurnSeen { endTurnReply = replyText.isEmpty ? nil : replyText }
        case "system":
            // Completion is an `end_turn` reply followed by its `turn_duration` record.
            guard object["subtype"] as? String == "turn_duration", endTurnSeen else { return }
            endTurnSeen = false
            guard let turn = old.turn ?? Self.identifier(object["uuid"]) else { return }
            if case .idle(let completed) = old.phase, completed == turn { return }
            var next = old
            next.phase = .idle(completedTurnID: turn); next.turn = turn; next.outcome = .unknown
            next.conclusion = endTurnReply
            content = next
        default:
            if !Self.ignoredTypes.contains(type) { unconfirm() }
        }
    }

    private mutating func consumeUser(_ object: [String: Any]) {
        guard let old = content, let message = object["message"] as? [String: Any],
              message["role"] as? String == "user", object["isMeta"] as? Bool != true else { return }
        let text = Self.promptText(message["content"])
        if let text, text.hasPrefix("[Request interrupted by user") {
            endTurnSeen = false
            guard let turn = old.turn else { unconfirm(); return }
            if case .idle = old.phase { return }
            resetReply()
            var next = old
            next.phase = .idle(completedTurnID: turn); next.outcome = .stopped; next.conclusion = nil
            content = next
            return
        }
        // Injected prompts, such as task notifications, are not developer input.
        guard let text, Self.isTypedPrompt(object) else { return }
        guard let input = Self.identifier(object["uuid"]) ?? Self.identifier(object["promptId"]),
              input != old.inputActivityID else { return }
        endTurnSeen = false
        resetReply()
        var next = old
        next.phase = .running; next.turn = Self.identifier(object["promptId"]) ?? input; next.outcome = .unknown
        next.inputActivityID = input; next.conclusion = nil
        next.localPreview = Self.preview(text) ?? old.localPreview
        content = next
    }

    static func isTypedPrompt(_ object: [String: Any]) -> Bool {
        let source = object["promptSource"] as? String
        let origin = (object["origin"] as? [String: Any])?["kind"] as? String
        if source == "system" || (origin != nil && origin != "human") { return false }
        return object["turnOrigin"] as? String == "human" || origin == "human" || source.map { promptSources.contains($0) } == true
    }
    /// Inspected releases are all 2.x; another major version makes state unknown.
    static func supportsVersion(_ version: String) -> Bool { version.split(separator: ".").first == "2" }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256 else { return nil }
        return text
    }
    /// The prompt's own text: a plain string or its first text part, never tool results.
    private static func promptText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]] else { return nil }
        return parts.first { $0["type"] as? String == "text" }?["text"] as? String
    }
    /// The latest request under the same rules as Codex previews: it never reaches logs, and only the owner's
    /// own completion notice carries an excerpt of it.
    private static func preview(_ text: String) -> String? {
        let normalized = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !normalized.isEmpty, !normalized.hasPrefix("<") else { return nil }
        return String(normalized.prefix(240))
    }
}

/// `ISO8601DateFormatter` is thread-safe, so one shared pair serves every reader.
final class ClaudeTimestamps: @unchecked Sendable {
    static let shared = ClaudeTimestamps()
    private let whole = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    func date(from value: String) -> Date? { fractional.date(from: value) ?? whole.date(from: value) }
}
