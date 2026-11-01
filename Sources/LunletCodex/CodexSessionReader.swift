// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-02, AC-02.08.
// Refs: US-15, AC-15.02.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.05; US-03, AC-03.01; US-11, AC-11.06; US-13, AC-13.01, AC-13.04.
// Refs: US-06, AC-06.02, AC-06.03, AC-06.05.
import Darwin
import Foundation
import CryptoKit
import LunletCore

struct CodexSessionContent: Equatable, Sendable {
    let id: UUID
    let project: String
    var phase: SessionPhase
    var turn: String?
    var conclusion: String?
    var outcome: TaskCue.Outcome = .unknown
    var inputActivityID: String? = nil
    var inputPending = false
    var localPreview: String? = nil

    /// Unconfirmed state keeps identity, turn and input evidence but no conclusion or outcome.
    func unconfirmed() -> Self {
        var next = self
        next.phase = .unknown; next.conclusion = nil; next.outcome = .unknown
        return next
    }
}
struct CodexSessionRead: Sendable {
    let content: CodexSessionContent
    let baseline: Bool
    let needsCatchup: Bool
    let lastActivityAt: Date?
    let parentSessionID: UUID?
}
enum CodexSessionReadFailure: Error { case unavailable, invalidIdentity }

/// Bounded local observation only. This never establishes a remote-input capability.
struct CodexSessionReader {
    let file: CodexRolloutFile
    /// Creation label only; it never establishes a CLI binding or input authority.
    private(set) var isCLISource = false
    private var parentSessionID: UUID?
    private var lastActivityAt: Date?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var droppingLine = false
    private var content: CodexSessionContent?
    /// The latest agent message of the current turn. It becomes the conclusion only when the turn completes
    /// and the completion record names no final message of its own.
    private var latestReply: String?
    private var recovering = false
    private let maximumLine = 2_097_152
    private let maximumRead = 4_194_304
    init(file: CodexRolloutFile) { self.file = file }

    mutating func read() throws -> CodexSessionRead {
        try Task.checkCancellation()
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CodexSessionReadFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode,
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw CodexSessionReadFailure.invalidIdentity }
        let size = UInt64(status.st_size)
        let resetting = content == nil || size < offset
        let baseline = resetting || recovering
        if resetting {
            let header = try readHeader(handle)
            content = header; lastActivityAt = nil; latestReply = nil; pending.removeAll(); droppingLine = false
            offset = size > maximumRead ? size - UInt64(maximumRead) : 0
            try handle.seek(toOffset: offset)
            if offset > 0 { droppingLine = true }
        } else { try handle.seek(toOffset: offset) }
        var budget = maximumRead
        while budget > 0, offset < size {
            try Task.checkCancellation()
            let count = min(65_536, budget, Int(size - offset))
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard !chunk.isEmpty else { break }
            offset += UInt64(chunk.count); budget -= chunk.count
            try consume(chunk)
        }
        guard let content else { throw CodexSessionReadFailure.invalidIdentity }
        let needsCatchup = offset < size
        recovering = needsCatchup
        let visible = needsCatchup ? content.unconfirmed() : content
        return .init(content: visible, baseline: baseline || needsCatchup, needsCatchup: needsCatchup, lastActivityAt: needsCatchup ? nil : lastActivityAt, parentSessionID: parentSessionID)
    }
    private mutating func readHeader(_ handle: FileHandle) throws -> CodexSessionContent {
        try handle.seek(toOffset: 0)
        var data = Data()
        while data.count <= maximumLine {
            let chunk = try handle.read(upToCount: 16_384) ?? Data()
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) { data.append(chunk[..<newline]); break }
            data.append(chunk)
        }
        guard data.count <= maximumLine,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { throw CodexSessionReadFailure.invalidIdentity }
        let source = payload["source"] as? String
        let sourceObject = payload["source"] as? [String: Any]
        let subagent = sourceObject?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        // Newer sub-agent variants name their parent only at the top level. Other sources,
        // such as forks, stay independent conversations even if they carry that field.
        let parent = spawn?["parent_thread_id"] as? String ?? (subagent != nil ? payload["parent_thread_id"] as? String : nil)
        parentSessionID = parent.flatMap(UUID.init(uuidString:))
        // Creation labels can be inherited from a daemon's earlier client.
        // Root activity remains read-only; labels never establish a CLI binding.
        isCLISource = source == "cli"
        guard let raw = payload["id"] as? String, let id = UUID(uuidString: raw),
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else {
            throw CodexSessionReadFailure.invalidIdentity
        }
        if parentSessionID == id { parentSessionID = nil }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        return .init(id: id, project: project.isEmpty ? "Project" : project, phase: .unknown, turn: nil, conclusion: nil)
    }
    private mutating func consume(_ chunk: Data) throws {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            let end = chunk[cursor...].firstIndex(of: 10) ?? chunk.endIndex
            if !droppingLine {
                if pending.count + end - cursor > maximumLine {
                    pending.removeAll(keepingCapacity: true); droppingLine = true; unconfirm()
                } else { pending.append(chunk[cursor..<end]) }
            }
            if end < chunk.endIndex {
                if !droppingLine, !pending.isEmpty { try consumeLine(pending) }
                pending.removeAll(keepingCapacity: true); droppingLine = false
            }
            cursor = end < chunk.endIndex ? end + 1 : end
        }
    }
    /// A dropped or unreadable line may have been the final message, so an earlier one never stands in for it.
    private mutating func unconfirm() {
        content = content?.unconfirmed(); latestReply = nil
    }
    private mutating func consumeLine(_ line: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any], let old = content else { unconfirm(); return }
        // Only an accepted semantic activity change can affect History recency.
        // File writes, polling, duplicate records and unrelated turns never do.
        defer {
            if content != old {
                if let raw = object["timestamp"] as? String, raw.utf8.count <= 128,
                   let date = RolloutTimestamps.shared.date(from: raw) {
                    lastActivityAt = max(lastActivityAt ?? date, date)
                } else { lastActivityAt = nil }
            }
        }
        // The first record is canonical. Copied forks persist inherited ancestor
        // metadata later in the same file; it never re-identifies this session.
        if object["type"] as? String == "session_meta" { return }
        // Steering can append input without another task_started event. The bounded
        // preview is the latest request; only the owner's own notice carries an excerpt.
        if object["type"] as? String == "response_item", payload["type"] as? String == "message",
           payload["role"] as? String == "user" {
            if Self.isInjectedContext(payload["content"]) { return }
            let explicit = payload["id"] as? String
            let input = explicit.flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
                ?? "record-" + SHA256.hash(data: line).prefix(16).map { String(format: "%02x", $0) }.joined()
            guard input != old.inputActivityID else { return }
            let running = old.phase == .running
            var next = old
            next.phase = running ? .running : .unknown; next.conclusion = nil; next.outcome = .unknown
            next.inputActivityID = input; next.inputPending = !running
            next.localPreview = Self.preview(payload["content"]) ?? old.localPreview
            if !running { latestReply = nil }
            content = next
            return
        }
        // The agent's visible messages, never reasoning or tool output. They change no session state.
        if let reply = Self.agentMessage(object["type"] as? String, payload) {
            latestReply = reply
            return
        }
        guard object["type"] as? String == "event_msg", let kind = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted"].contains(kind),
              let turn = payload["turn_id"] as? String, !turn.isEmpty, turn.utf8.count <= 256 else { return }
        var next = old
        next.inputPending = false
        if kind == "task_started" {
            next.phase = .running; next.turn = turn; next.conclusion = nil; next.outcome = .unknown
            latestReply = nil
            content = next
        } else {
            guard old.turn == nil || old.turn == turn else { return }
            // The first confirmed terminal event owns this turn's outcome.
            if case .idle = old.phase { return }
            // `task_complete` names the final message; older or partial records fall back to the turn's
            // latest agent message. It carries no success or failure, so the outcome stays unknown.
            var reply: String?
            if kind == "task_complete" {
                reply = (payload["last_agent_message"] as? String).flatMap(Self.bounded) ?? latestReply
            }
            latestReply = nil
            next.phase = .idle(completedTurnID: turn); next.turn = turn
            next.conclusion = reply
            next.outcome = kind == "turn_aborted" ? .stopped : .unknown
            content = next
        }
    }

    /// The text of a visible agent message: an `agent_message` event or an assistant `output_text` item.
    private static func agentMessage(_ type: String?, _ payload: [String: Any]) -> String? {
        if type == "event_msg", payload["type"] as? String == "agent_message" {
            return (payload["message"] as? String).flatMap(bounded)
        }
        guard type == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "assistant",
              let parts = payload["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
        return bounded(text)
    }
    /// A non-empty reply within the capture bound, so one record cannot hold an unbounded summary.
    private static func bounded(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : NoticeText.prefix(text, utf8Limit: NoticeText.captureLimit)
    }

    private static func preview(_ value: Any?) -> String? {
        guard let parts = value as? [[String: Any]], let text = parts.first(where: { $0["type"] as? String == "input_text" })?["text"] as? String else { return nil }
        let normalized = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !normalized.isEmpty, !normalized.hasPrefix("<") else { return nil }
        guard !normalized.lowercased().hasPrefix("the following is the codex agent history added since your last approval assessment") else { return nil }
        return String(normalized.prefix(240))
    }
    private static func isInjectedContext(_ value: Any?) -> Bool {
        guard let parts = value as? [[String: Any]] else { return false }
        return parts.contains { part in
            guard part["type"] as? String == "input_text", let text = part["text"] as? String else { return false }
            return isContextualFragment(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    /// Mirrors Codex's marked-fragment rule: hidden runtime context, such as
    /// environment, instruction, interruption and shell records, opens and closes
    /// with one matching marker. Such records are not developer input.
    static func isContextualFragment(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("# agents.md instructions") {
            return lowered.hasSuffix("</instructions>") || lowered.contains("<instructions>")
        }
        guard lowered.first == "<", let close = lowered.firstIndex(of: ">") else { return false }
        let tag = lowered[lowered.index(after: lowered.startIndex)..<close].prefix { !$0.isWhitespace }
        guard !tag.isEmpty, tag.utf8.count <= 64,
              tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return false }
        return lowered.hasSuffix("</" + tag + ">")
    }
}
