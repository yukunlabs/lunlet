// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.03, AC-33.04, AC-33.06, AC-33.07.
// Synthetic Claude Code 2.1-shaped records under a per-test temporary root; no real Claude data is read.
import Foundation
@testable import LunletClaude

struct ClaudeFixture {
    let root: URL
    var home: ClaudeHome { .init(root: root) }
    static let first = "0b6b2a52-5f0e-4c5c-9d43-3c4f0a1b2c01"
    static let second = "0b6b2a52-5f0e-4c5c-9d43-3c4f0a1b2c02"
    static let cwd = "/tmp/synthetic/project-a"
    /// 2026-10-30T10:00:00Z in Claude's `ps -o lstart` UTC form.
    static let processStart = "Fri Oct 30 10:00:00 2026"
    static let startDate = Date(timeIntervalSince1970: 1_793_354_400)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func record(pid: Int32, session: String, cwd: String = cwd, procStart: Any = processStart, status: String = "busy",
                waitingFor: String? = nil, version: String = "2.1.314") throws -> URL {
        var object: [String: Any] = ["pid": Int(pid), "sessionId": session, "cwd": cwd, "startedAt": 1_793_354_400_000,
                                     "procStart": procStart, "version": version, "kind": "interactive", "entrypoint": "cli",
                                     "status": status, "statusUpdatedAt": 1_793_354_405_000]
        if let waitingFor { object["waitingFor"] = waitingFor }
        let url = root.appendingPathComponent("sessions/\(pid).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }
    func projectDirectory(cwd: String = cwd) -> URL {
        root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ClaudeProjects.encodedDirectoryName(cwd), isDirectory: true)
    }
    @discardableResult
    func transcript(_ lines: [String], session: String, cwd: String = cwd) throws -> URL {
        let directory = projectDirectory(cwd: cwd)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(session + ".jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }
    @discardableResult
    func subagent(_ lines: [String], session: String, agent: String = "agent-a1", cwd: String = cwd) throws -> URL {
        let directory = projectDirectory(cwd: cwd).appendingPathComponent(session).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(agent + ".jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }
    func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }
    func file(_ url: URL) throws -> ClaudeTranscriptFile {
        guard let file = ClaudeProjects.regularFile(url) else { throw CocoaError(.fileNoSuchFile) }
        return file
    }

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func typed(_ text: String, uuid: String, prompt: String, session: String = first,
                      at time: String = "2026-10-30T10:00:01.000Z") -> String {
        line(["type": "user", "uuid": uuid, "promptId": prompt, "sessionId": session, "timestamp": time, "version": "2.1.314",
              "isSidechain": false, "promptSource": "typed", "turnOrigin": "human", "origin": ["kind": "human"],
              "message": ["role": "user", "content": text]])
    }
    /// A task notification Claude injects as a prompt; it is not developer input.
    static func injected(uuid: String, prompt: String, session: String = first) -> String {
        line(["type": "user", "uuid": uuid, "promptId": prompt, "sessionId": session, "timestamp": "2026-10-30T10:00:05.000Z",
              "version": "2.1.314", "promptSource": "system", "origin": ["kind": "task-notification"],
              "message": ["role": "user", "content": [["type": "text", "text": "<task-notification>done</task-notification>"]]]])
    }
    static func meta(uuid: String, session: String = first) -> String {
        line(["type": "user", "uuid": uuid, "promptId": "meta", "sessionId": session, "timestamp": "2026-10-30T10:00:01.500Z",
              "isMeta": true, "promptSource": "typed", "message": ["role": "user", "content": "Caveat: injected"]])
    }
    static func interrupted(session: String = first) -> String {
        line(["type": "user", "uuid": UUID().uuidString.lowercased(), "promptId": "p-int", "sessionId": session,
              "timestamp": "2026-10-30T10:00:04.000Z", "version": "2.1.314",
              "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])
    }
    static func toolResult(session: String = first) -> String {
        line(["type": "user", "uuid": UUID().uuidString.lowercased(), "promptId": "p1", "sessionId": session,
              "timestamp": "2026-10-30T10:00:02.500Z", "version": "2.1.314", "toolUseResult": ["stdout": "synthetic"],
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "synthetic"]]]])
    }
    static func usage(input: Int = 10, write5m: Int = 100, write1h: Int = 0, read: Int = 1_000, output: Int = 50,
                      geo: String = "global", speed: String = "standard") -> [String: Any] {
        ["input_tokens": input, "cache_creation_input_tokens": write5m + write1h, "cache_read_input_tokens": read,
         "output_tokens": output, "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
         "service_tier": "standard", "inference_geo": geo, "speed": speed]
    }
    /// One record per content block, as Claude writes them; `stop` nil models an intermediate block record.
    static func assistant(stop: String?, id: String = "msg_1", model: String = "claude-opus-5-5", session: String = first,
                          usage: [String: Any] = usage(), at time: String = "2026-10-30T10:00:03.000Z",
                          content: [[String: Any]] = [["type": "text", "text": "Synthetic reply"]],
                          uuid: String = UUID().uuidString.lowercased(), sidechain: Bool = false) -> String {
        line(["type": "assistant", "uuid": uuid, "sessionId": session, "timestamp": time,
              "version": "2.1.314", "isSidechain": sidechain, "requestId": "req_1",
              "message": ["id": id, "role": "assistant", "type": "message", "model": model, "stop_reason": stop.map { $0 as Any } ?? NSNull(),
                          "content": content, "usage": usage]])
    }
    static func turnDuration(uuid: String = "c0ffee00-0000-4000-8000-000000000001", session: String = first,
                             at time: String = "2026-10-30T10:00:03.500Z") -> String {
        line(["type": "system", "subtype": "turn_duration", "uuid": uuid, "sessionId": session, "timestamp": time,
              "version": "2.1.314", "durationMs": 2_500, "isMeta": false])
    }
    static func ignored(session: String = first) -> String {
        line(["type": "permission-mode", "permissionMode": "default", "sessionId": session])
    }
}
