// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.06, AC-33.07.
// Refs: US-13, AC-13.01, AC-13.04; US-15, AC-15.02, AC-15.06; US-06, AC-06.02, AC-06.05; US-33, AC-33.05; US-38, AC-38.05.
// Refs: US-25, AC-25.01.
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
    /// How many follow-ups Lunlet's hook handed to this turn; each one completes again under a suffixed id.
    var continuations = 0

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
    /// The first and last bytes of an oversized line while it is dropped: its content is never kept, but the members
    /// around the oversized one tell which record it was.
    private var droppedHead: Data?
    private var droppedTail = Data()

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
            droppedHead = nil; droppedTail.removeAll()
            resetReply()
            // Initial state comes from the latest bounded tail; a partial first line is skipped.
            offset = size > UInt64(Self.maximumRead) ? size - UInt64(Self.maximumRead) : 0
            droppingLine = offset > 0
        }
        try handle.seek(toOffset: offset)
        var budget = Self.maximumRead
        while budget > 0, offset < size {
            try Task.checkCancellation()
            // Foundation returns each chunk and each decoded record autoreleased. A scan reads every session's tail
            // in one job, so without a pool per chunk all of them stay allocated until that job ends (AC-25.01).
            let more = try autoreleasepool { () throws -> Bool in
                let chunk = try handle.read(upToCount: min(65_536, budget, Int(size - offset))) ?? Data()
                guard !chunk.isEmpty else { return false }
                offset += UInt64(chunk.count); budget -= chunk.count
                consume(chunk)
                return true
            }
            if !more { break }
        }
        guard let content else { throw ClaudeTranscriptFailure.invalidIdentity }
        let needsCatchup = offset < size
        recovering = needsCatchup
        return .init(content: needsCatchup ? content.unconfirmed() : content, baseline: baseline || needsCatchup,
                     needsCatchup: needsCatchup, lastActivityAt: needsCatchup ? nil : lastActivityAt)
    }

    /// Lines over the bound are dropped; they make state unknown, never a read failure. Only the first and last
    /// bytes of such a line are looked at, for the one record that must not be missed: a typed prompt.
    private mutating func consume(_ chunk: Data) {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            let end = chunk[cursor...].firstIndex(of: 10) ?? chunk.endIndex
            let slice = chunk[cursor..<end]
            if droppingLine {
                if droppedHead != nil { keepTail(slice) }
            } else if pending.count + slice.count > Self.maximumLine {
                var head = Data(pending.prefix(ClaudeRecordProbe.bytes))
                if head.count < ClaudeRecordProbe.bytes { head.append(slice.prefix(ClaudeRecordProbe.bytes - head.count)) }
                droppedHead = head
                droppedTail = Data(pending.suffix(ClaudeRecordProbe.bytes)); keepTail(slice)
                pending.removeAll(keepingCapacity: true); droppingLine = true
                // A record of a type this reader passes over when it can decode it changes nothing when it cannot
                // either; any other record, or one whose first bytes do not name its type, leaves the state unknown.
                if !Self.passesOver(ClaudeRecordProbe.leading(head)["type"]) { unconfirm() }
            } else { pending.append(slice) }
            if end < chunk.endIndex {
                if droppingLine {
                    if let head = droppedHead { consumeOversized(head: head, tail: droppedTail) }
                    droppedHead = nil; droppedTail.removeAll()
                } else if !pending.isEmpty { consumeLine(pending) }
                pending.removeAll(keepingCapacity: true); droppingLine = false
            }
            cursor = end < chunk.endIndex ? end + 1 : end
        }
    }
    /// The record types `consumeLine` acts on; every other type is read and ignored.
    private static let consumedTypes: Set<String> = ["user", "assistant", "system"]
    private static func passesOver(_ type: String?) -> Bool { type.map { !consumedTypes.contains($0) } ?? false }
    private mutating func keepTail(_ slice: Data) {
        if slice.count >= ClaudeRecordProbe.bytes { droppedTail = Data(slice.suffix(ClaudeRecordProbe.bytes)); return }
        droppedTail.append(slice)
        if droppedTail.count > ClaudeRecordProbe.bytes { droppedTail = Data(droppedTail.suffix(ClaudeRecordProbe.bytes)) }
    }

    /// A typed prompt with pasted images can exceed the line bound. Its content is not read, but the record's own
    /// members before and after the oversized one say that this session's developer started a new turn, and under
    /// which id. Without that the reader would stay on the previous turn, whose id would then complete a second
    /// time and be taken for a replay (AC-13.04). Anything less certain keeps the unknown state a dropped line has.
    private mutating func consumeOversized(head: Data, tail: Data) {
        var fields = ClaudeRecordProbe.leading(head)
        fields.merge(ClaudeRecordProbe.trailing(tail)) { first, _ in first }
        guard let old = content, fields["type"] == "user", fields["isSidechain"] != "true", fields["isMeta"] != "true",
              fields["version"].map(Self.supportsVersion) ?? true,
              fields["sessionId"].map({ $0.lowercased() == sessionName }) ?? true,
              // Developer input only, by the same members a decoded prompt is judged by.
              fields["promptSource"] != "system",
              fields["turnOrigin"] == "human" || fields["promptSource"].map(Self.promptSources.contains) == true,
              let prompt = Self.identifier(fields["promptId"]), prompt != old.turn else { return }
        let input = Self.identifier(fields["uuid"]) ?? prompt
        guard input != old.inputActivityID else { return }
        endTurnSeen = false
        resetReply()
        var next = old
        next.phase = .running; next.turn = prompt; next.outcome = .unknown
        next.inputActivityID = input; next.conclusion = nil; next.continuations = 0
        // The request's text was not read; the previous request must not stand in for it.
        next.localPreview = nil
        content = next
        if let raw = fields["timestamp"], raw.utf8.count <= 64, let date = ClaudeTimestamps.shared.date(from: raw) {
            lastActivityAt = max(lastActivityAt ?? date, date)
        } else { lastActivityAt = nil }
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
            let subtype = object["subtype"] as? String
            if subtype == "stop_hook_summary" {
                // Lunlet's hook handed the owner's follow-up over: the turn goes on as if it had been typed.
                guard let followup = ClaudeHookRecord.followups(in: object).first, old.turn != nil else { return }
                endTurnSeen = false; resetReply()
                var next = old
                next.phase = .running; next.outcome = .unknown; next.conclusion = nil; next.continuations += 1
                next.localPreview = Self.preview(followup) ?? old.localPreview
                content = next
                return
            }
            // Completion is an `end_turn` reply followed by its `turn_duration` record.
            guard subtype == "turn_duration", endTurnSeen else { return }
            endTurnSeen = false
            guard let base = old.turn ?? Self.identifier(object["uuid"]) else { return }
            let turn = ClaudeTurnID.compose(base, continuations: old.continuations)
            if case .idle(let completed) = old.phase, completed == turn { return }
            var next = old
            next.phase = .idle(completedTurnID: turn); next.turn = base; next.outcome = .unknown
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
        next.inputActivityID = input; next.conclusion = nil; next.continuations = 0
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

/// Reads the scalar members at the top level of a JSON object from its first or its last bytes alone, for a record
/// too large to decode. Strings are decoded exactly and `true` and `false` are kept as those words; numbers, `null`
/// and nested values are skipped, and the scan stops at the first member that is cut off, so nothing is guessed
/// from inside the oversized part.
enum ClaudeRecordProbe {
    static let bytes = 2_048
    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":"), comma = UInt8(ascii: ",")
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A }
    private static func opens(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") }
    private static func closes(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") }
    private static func text(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count <= 1_024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed)) as? String
    }
    private static func word(_ bytes: ArraySlice<UInt8>) -> String? {
        let value = String(decoding: bytes, as: UTF8.self)
        return value == "true" || value == "false" ? value : nil
    }

    /// The members before the first one that does not end within `data`.
    static func leading(_ data: Data) -> [String: String] {
        let b = [UInt8](data)
        var fields: [String: String] = [:], i = 0
        func skip() { while i < b.count, isSpace(b[i]) { i += 1 } }
        skip()
        guard i < b.count, b[i] == UInt8(ascii: "{") else { return fields }
        i += 1
        while true {
            skip()
            guard i < b.count, b[i] == quote, let keyEnd = stringEnd(b, from: i), let key = text(b[i...keyEnd]) else { return fields }
            i = keyEnd + 1; skip()
            guard i < b.count, b[i] == colon else { return fields }
            i += 1; skip()
            guard i < b.count else { return fields }
            if b[i] == quote {
                guard let end = stringEnd(b, from: i) else { return fields }
                if let value = text(b[i...end]) { fields[key] = value }
                i = end + 1
            } else if opens(b[i]) {
                guard let end = containerEnd(b, from: i) else { return fields }
                i = end + 1
            } else {
                let start = i
                while i < b.count, b[i] != comma, !closes(b[i]), !isSpace(b[i]) { i += 1 }
                guard i < b.count else { return fields }
                if let value = word(b[start..<i]) { fields[key] = value }
            }
            skip()
            guard i < b.count, b[i] == comma else { return fields }
            i += 1
        }
    }

    /// The members after the last one that does not begin within `data`, which must end with the object's brace.
    static func trailing(_ data: Data) -> [String: String] {
        let b = [UInt8](data)
        var fields: [String: String] = [:], i = b.count - 1
        func skip() { while i >= 0, isSpace(b[i]) { i -= 1 } }
        skip()
        guard i >= 0, b[i] == UInt8(ascii: "}") else { return fields }
        i -= 1
        while true {
            skip()
            guard i >= 0 else { return fields }
            var value: String?
            if b[i] == quote {
                guard let start = stringStart(b, endingAt: i) else { return fields }
                value = text(b[start...i]); i = start - 1
            } else if closes(b[i]) {
                guard let start = containerStart(b, endingAt: i) else { return fields }
                i = start - 1
            } else {
                let end = i
                while i >= 0, b[i] != colon, !isSpace(b[i]) { i -= 1 }
                value = word(b[(i + 1)...end])
            }
            skip()
            guard i >= 0, b[i] == colon else { return fields }
            i -= 1; skip()
            guard i >= 0, b[i] == quote, let keyStart = stringStart(b, endingAt: i), let key = text(b[keyStart...i]) else { return fields }
            if let value, fields[key] == nil { fields[key] = value }
            i = keyStart - 1; skip()
            guard i >= 0, b[i] == comma else { return fields }
            i -= 1
        }
    }

    /// The index of the quote closing the string that opens at `start`.
    private static func stringEnd(_ b: [UInt8], from start: Int) -> Int? {
        var j = start + 1
        while j < b.count {
            if b[j] == backslash { j += 2 } else if b[j] == quote { return j } else { j += 1 }
        }
        return nil
    }
    private static func containerEnd(_ b: [UInt8], from start: Int) -> Int? {
        var depth = 0, j = start
        while j < b.count {
            if b[j] == quote {
                guard let end = stringEnd(b, from: j) else { return nil }
                j = end + 1; continue
            }
            if opens(b[j]) { depth += 1 } else if closes(b[j]) { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
    /// The index of the quote opening the string that closes at `end`: the nearest earlier quote that is not
    /// escaped. A run of backslashes that reaches the first byte cannot be counted, so the scan gives up there.
    private static func stringStart(_ b: [UInt8], endingAt end: Int) -> Int? {
        var j = end - 1
        while j >= 0 {
            if b[j] == quote {
                var k = j - 1, escapes = 0
                while k >= 0, b[k] == backslash { escapes += 1; k -= 1 }
                if k < 0, escapes > 0 { return nil }
                if escapes % 2 == 0 { return j }
            }
            j -= 1
        }
        return nil
    }
    private static func containerStart(_ b: [UInt8], endingAt end: Int) -> Int? {
        var depth = 0, j = end
        while j >= 0 {
            if b[j] == quote {
                guard let start = stringStart(b, endingAt: j) else { return nil }
                j = start - 1; continue
            }
            if closes(b[j]) { depth += 1 } else if opens(b[j]) { depth -= 1; if depth == 0 { return j } }
            j -= 1
        }
        return nil
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

/// The id of a completed turn: the prompt id, suffixed with the number of hook continuations it had, so a turn
/// that Lunlet's hook continued completes again under a new id and the first completion is never replayed.
enum ClaudeTurnID {
    static func compose(_ base: String, continuations: Int) -> String {
        continuations > 0 ? base + "#" + String(continuations) : base
    }
}
