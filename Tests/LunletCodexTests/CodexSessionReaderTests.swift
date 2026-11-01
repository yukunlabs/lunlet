// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-02, AC-02.08.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.05; US-03, AC-03.01; US-11, AC-11.06; US-13, AC-13.01, AC-13.04.
// Refs: US-06, AC-06.02, AC-06.03, AC-06.05.
import Darwin
import Foundation
import Testing
import LunletCore
@testable import LunletCodex

struct CodexSessionReaderTests {
    @Test func parentThreadIsTakenOnlyFromStructuredSubagentMetadata() throws {
        let child = try header(first, source: ["subagent": ["thread_spawn": ["parent_thread_id": second.uuidString]]])
        let (root, file) = try fixture(child)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().parentSessionID == second)
    }
    // Refs: US-02, AC-02.01; US-15, AC-15.02: 0.165+ sub-agents name their parent only at the top level.
    @Test func subagentParentMayBeRecordedAtTheTopLevelButOtherSourcesStayIndependent() throws {
        let parent = ["parent_thread_id": second.uuidString]
        for (source, expected) in [(["subagent": ["other": "synthetic-role"]] as Any, second as UUID?), ("cli", nil), ("vscode", nil)] {
            let (root, file) = try fixture(header(first, source: source, extra: parent))
            defer { try? FileManager.default.removeItem(at: root) }
            var reader = CodexSessionReader(file: file)
            #expect(try reader.read().parentSessionID == expected)
        }
    }
    @Test func injectedAgentInstructionsAreNotAUserMessageOrPreview() throws {
        let user = try line("response_item", ["type": "message", "role": "user", "id": "one", "content": [["type": "input_text", "text": "Improve the layout"]]])
        let instructions = try line("response_item", ["type": "message", "role": "user", "id": "two", "content": [["type": "input_text", "text": "# AGENTS.md instructions for /synthetic/project\n<INSTRUCTIONS>\nSynthetic rules\n</INSTRUCTIONS>"]]])
        let (root, file) = try fixture(header(first) + user + instructions)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        let result = try reader.read().content
        #expect(result.localPreview == "Improve the layout")
        #expect(result.inputActivityID == "one")
    }
    // Refs: US-15, AC-15.02; US-13, AC-13.01.
    @Test func markedRuntimeContextIsNotNewInputWhileDeveloperMarkupStillIs() throws {
        let user = try line("response_item", ["type": "message", "role": "user", "id": "one", "content": [["type": "input_text", "text": "Improve the layout"]]])
        let (root, file) = try fixture(header(first) + user + event("task_started", "turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().content.inputActivityID == "one")
        let injected = [
            "<environment_context>\n  <cwd>/synthetic/project</cwd>\n</environment_context>",
            "<user_instructions>\nSynthetic rules\n</user_instructions>",
            "<TURN_ABORTED>\nSynthetic interruption\n</turn_aborted>",
            "  <user_shell_command attribute=\"synthetic\">ls</user_shell_command>  ",
        ]
        for (index, text) in injected.enumerated() {
            try append(line("response_item", ["type": "message", "role": "user", "id": "context-\(index)", "content": [["type": "input_text", "text": text]]]), to: file)
            let content = try reader.read().content
            #expect(content.inputActivityID == "one" && !content.inputPending && content.localPreview == "Improve the layout")
        }
        // Unmatched markup is still developer input; only Codex's marked fragments are hidden.
        for (index, text) in ["<div> not closed", "<b>bold</i>", "</environment_context>"].enumerated() {
            try append(line("response_item", ["type": "message", "role": "user", "id": "markup-\(index)", "content": [["type": "input_text", "text": text]]]), to: file)
            #expect(try reader.read().content.inputActivityID == "markup-\(index)")
        }
    }
    @Test func internalApprovalHistoryDoesNotReplaceConversationPreview() throws {
        let user = try line("response_item", ["type": "message", "role": "user", "id": "one", "content": [["type": "input_text", "text": "Improve the session list"]]])
        let internalMessage = try line("response_item", ["type": "message", "role": "user", "id": "two", "content": [["type": "input_text", "text": "The following is the Codex agent history added since your last approval assessment. Continue reviewing."]]])
        let (root, file) = try fixture(header(first) + user + internalMessage)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().content.localPreview == "Improve the session list")
    }
    @Test func latestUserTextProvidesBoundedLocalPreviewAcrossTurnEvents() throws {
        let message = try line("response_item", ["type": "message", "role": "user", "id": "input-one", "content": [["type": "input_text", "text": "  Fix the session list\nnext  "]]])
        let (root, file) = try fixture(header(first) + message + event("task_started", "turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().content.localPreview == "Fix the session list next")
        try append(event("task_complete", "turn"), to: file)
        #expect(try reader.read().content.localPreview == "Fix the session list next")
        let second = try line("response_item", ["type": "message", "role": "user", "id": "input-two", "content": [["type": "input_text", "text": "Another task"]]])
        try append(second, to: file)
        #expect(try reader.read().content.localPreview == "Another task")
    }
    @Test func previewWorksForUserMessagesWithoutAnExplicitIdentifier() throws {
        let message = try line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Investigate the layout"]]])
        let (root, file) = try fixture(header(first) + message)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        let result = try reader.read().content
        #expect(result.localPreview == "Investigate the layout")
        #expect(result.inputActivityID != nil)
    }
    @Test func previewIsBoundedAndIgnoresNonUserAndNonTextContent() throws {
        let user = try line("response_item", ["type": "message", "role": "user", "id": "one", "content": [["type": "input_text", "text": String(repeating: "a", count: 300)]]])
        let assistant = try line("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Synthetic output"]]])
        let (root, file) = try fixture(header(first) + user + assistant)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        // Long enough for the notice's 140-character request excerpt (AC-06.02), still bounded.
        #expect(try reader.read().content.localPreview == String(repeating: "a", count: 240))
    }
    let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        data.append(10); return data
    }
    func header(_ id: UUID, source: Any = "cli", extra: [String: Any] = [:]) throws -> Data {
        try line("session_meta", extra.merging(["id": id.uuidString, "cwd": "/synthetic/shared-project", "source": source]) { _, own in own })
    }
    func event(_ name: String, _ id: String, extra: [String: Any] = [:]) throws -> Data {
        try line("event_msg", extra.merging(["type": name, "turn_id": id]) { _, right in right })
    }
    func fixture(_ content: Data) throws -> (URL, CodexRolloutFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-observation-\(UUID())/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rollout.jsonl")
        try content.write(to: url)
        var status = stat(); #expect(lstat(url.path, &status) == 0)
        return (root.deletingLastPathComponent(), .init(url: url.resolvingSymlinksInPath(), device: status.st_dev, inode: status.st_ino))
    }
    func append(_ data: Data, to file: CodexRolloutFile) throws {
        let h = try FileHandle(forWritingTo: file.url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: data)
    }
    @Test func runtimeModeAcceptsRootActivityWithoutTreatingCreationLabelsAsClientIdentity() throws {
        for origin in ["codex-tui", "codex_cli_rs", "Codex Desktop", "unknown-cli", ""] {
            let data = try line("session_meta", ["id": first.uuidString, "source": "vscode", "originator": origin, "cwd": "/synthetic/project"])
            let (root, file) = try fixture(data + event("task_started", "turn"))
            defer { try? FileManager.default.removeItem(at: root) }
            var reader = CodexSessionReader(file: file)
            #expect(try reader.read().content.phase == .running)
        }
        #expect(CodexProcessReader.role(arguments: ["codex", "app-server", "--listen", "unix://"], terminalAttached: false) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "queue", "app-server"], terminalAttached: false) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "app-server"], terminalAttached: true) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "--enable", "hooks", "app-server"], terminalAttached: false) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "-c", "x=y", "app-server"], terminalAttached: false) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "--", "app-server"], terminalAttached: false) == .sharedRuntime)
        #expect(CodexProcessReader.role(arguments: ["codex", "Explain app-server"], terminalAttached: true) == .terminalCLI)
    }

    func timedEvent(_ name: String, _ turn: String, at timestamp: String) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: event(name, turn)) as? [String: Any])
        object["timestamp"] = timestamp
        return try JSONSerialization.data(withJSONObject: object) + Data([10])
    }

    @Test func sourceActivityTimeIgnoresMetadataDuplicatesAndUnrelatedTurns() throws {
        let time = "2026-10-28T10:00:00Z"
        let (root, file) = try fixture(header(first) + timedEvent("task_started", "one", at: time))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().lastActivityAt == ISO8601DateFormatter().date(from: time))
        try append(timedEvent("task_started", "one", at: "2026-10-28T15:00:00Z") + timedEvent("task_complete", "other", at: "2026-10-28T16:00:00Z"), to: file)
        #expect(try reader.read().lastActivityAt == ISO8601DateFormatter().date(from: time))
        let completed = "2026-10-28T11:00:00Z"
        try append(timedEvent("task_complete", "one", at: completed), to: file)
        #expect(try reader.read().lastActivityAt == ISO8601DateFormatter().date(from: completed))
        try append(timedEvent("task_started", "two", at: "invalid"), to: file)
        #expect(try reader.read().lastActivityAt == nil)
    }

    @Test func everyLocalSourceIsObservableWithoutGrantingCLIIdentity() throws {
        let sources: [Any] = ["cli", "vscode", "appServer", "exec", "unknown", "future-source",
                              ["subagent": ["thread_spawn": ["parent_thread_id": second.uuidString]]], NSNull()]
        for source in sources {
            let (root, file) = try fixture(header(first, source: source) + event("task_started", "turn"))
            defer { try? FileManager.default.removeItem(at: root) }
            var reader = CodexSessionReader(file: file)
            #expect(try reader.read().content.phase == .running)
            try append(event("task_complete", "turn"), to: file)
            #expect(try reader.read().content.phase == .idle(completedTurnID: "turn"))
        }
    }

    // Refs: US-13, AC-13.01, AC-13.07.
    @Test func confirmedAbortIsStoppedWhileOrdinaryCompletionRemainsUnknown() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "one"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file); _ = try reader.read()
        try append(event("turn_aborted", "other"), to: file)
        #expect(try reader.read().content.phase == .running)
        try append(event("turn_aborted", "one"), to: file)
        #expect(try reader.read().content.outcome == .stopped)
        try append(event("task_complete", "one"), to: file)
        #expect(try reader.read().content.outcome == .stopped)
        try append(event("task_started", "two"), to: file)
        #expect(try reader.read().content.outcome == .unknown)
        try append(event("task_complete", "two"), to: file)
        #expect(try reader.read().content.outcome == .unknown)
        try append(event("turn_aborted", "two"), to: file)
        #expect(try reader.read().content.outcome == .unknown)
    }

    @Test func baselineAndLiveAppendsPreserveTurnAndSessionIdentity() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "turn-a"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        let baseline = try reader.read()
        #expect(baseline.baseline && baseline.content.id == first)
        #expect(baseline.content.project == "shared-project")
        #expect(baseline.content.phase == .running && baseline.content.turn == "turn-a")
        try append(try event("task_complete", "turn-a", extra: ["last_agent_message": "Synthetic result."]), to: file)
        let finished = try reader.read()
        #expect(!finished.baseline && finished.content.phase == .idle(completedTurnID: "turn-a"))
        #expect(finished.content.conclusion == "Synthetic result.")
        #expect(try reader.read().content == finished.content)
        try append(try event("task_started", "turn-b"), to: file)
        #expect(try reader.read().content.conclusion == nil)
    }
    // Refs: US-15, AC-15.02; US-13, AC-13.07.
    @Test func userInputMetadataTracksSteeringWithoutReadingItsBodyOrInventingATurn() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "same-turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file); _ = try reader.read()
        try append(try line("response_item", ["type": "message", "role": "user", "id": "input-one",
            "content": [["text": "Private synthetic instruction"]]]), to: file)
        let steered = try reader.read()
        #expect(!steered.baseline && steered.content.inputActivityID == "input-one")
        #expect(steered.content.phase == .running && steered.content.turn == "same-turn")
        #expect(steered.content.conclusion == nil)
        try append(try event("task_complete", "same-turn"), to: file)
        #expect(try reader.read().content.phase == .idle(completedTurnID: "same-turn"))
        try append(try line("response_item", ["type": "message", "role": "user", "id": "input-two"]), to: file)
        let queued = try reader.read()
        #expect(queued.content.inputPending && queued.content.phase == .unknown)
        #expect(queued.content.inputActivityID == "input-two" && queued.content.turn == "same-turn")
        try append(try event("task_started", "next-turn"), to: file)
        let started = try reader.read()
        #expect(!started.content.inputPending && started.content.phase == .running)
        #expect(started.content.turn == "next-turn" && started.content.inputActivityID == "input-two")
    }

    @Test func partialLinesAndStaleCompletionCannotFinishANewerTurn() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "new"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file); _ = try reader.read()
        let end = try event("task_complete", "new")
        try append(end.prefix(end.count / 2), to: file)
        #expect(try reader.read().content.phase == .running)
        try append(end.suffix(end.count - end.count / 2), to: file)
        #expect(try reader.read().content.phase == .idle(completedTurnID: "new"))
        try append(try event("task_started", "later") + event("task_complete", "new"), to: file)
        #expect(try reader.read().content.phase == .running)
        #expect(try reader.read().content.turn == "later")
    }
    @Test func nonCLIMetadataCannotEstablishIdentityAndInheritedMetadataCannotReplaceIt() throws {
        // Non-CLI records remain readable runtime activity, but their creation label never
        // marks them as CLI-origin; the monitor then grants only shared-runtime roles.
        for source in ["vscode", ["subagent": ["thread_spawn": [:]]]] as [Any] {
            let (root, file) = try fixture(header(first, source: source))
            defer { try? FileManager.default.removeItem(at: root) }
            var reader = CodexSessionReader(file: file)
            #expect(try reader.read().content.id == first)
            #expect(!reader.isCLISource)
        }
        // A copied fork keeps its own metadata first, then persists the ancestor's
        // records. The first record remains the only identity for every later event.
        let (root, file) = try fixture(header(first) + header(second) + event("task_started", "inherited"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        let inherited = try reader.read().content
        #expect(inherited.id == first && inherited.turn == "inherited")
        try append(header(second) + event("task_complete", "inherited"), to: file)
        let current = try reader.read().content
        #expect(current.id == first && current.phase == .idle(completedTurnID: "inherited"))
    }
    // Refs: US-06, AC-06.02, AC-06.05: reasoning and tool output never become the result; long replies are bounded.
    @Test func reasoningAndToolOutputNeverBecomeTheResultWhileLongRepliesAreKeptBounded() throws {
        let data = try header(first) + event("task_started", "t")
            + line("response_item", ["type": "reasoning", "text": "Private synthetic reasoning"])
            + line("response_item", ["type": "function_call_output", "output": "Private synthetic tool result"])
            + line("event_msg", ["type": "agent_reasoning", "text": "Private synthetic reasoning"])
        let (root, file) = try fixture(data)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        #expect(try reader.read().content.conclusion == nil)
        try append(try event("task_complete", "t"), to: file)
        #expect(try reader.read().content.conclusion == nil)
        // A real final reply is usually far longer than the former 480-byte bound; it is kept up to the capture limit.
        try append(try event("task_started", "u") + event("task_complete", "u", extra: ["last_agent_message": String(repeating: "x", count: 3000)]), to: file)
        #expect(try reader.read().content.conclusion == String(repeating: "x", count: 3000))
        try append(try event("task_started", "v") + event("task_complete", "v", extra: ["last_agent_message": String(repeating: "é", count: 30_000)]), to: file)
        let bounded = try #require(try reader.read().content.conclusion)
        #expect(bounded.utf8.count <= NoticeText.captureLimit && bounded.utf8.count > NoticeText.captureLimit - 2)
    }

    // Refs: US-06, AC-06.02, AC-06.03: without `last_agent_message`, the turn's latest agent message is the result.
    @Test func completionFallsBackToTheTurnsLatestAgentMessage() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "t")
            + line("event_msg", ["type": "agent_message", "message": "Looking at the parser first."])
            + line("response_item", ["type": "message", "role": "assistant",
                                     "content": [["type": "output_text", "text": "Fixed the parser."], ["type": "output_text", "text": "Tests pass."]]]))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file)
        let running = try reader.read()
        // Agent messages change no state or recency until the turn completes.
        #expect(running.content.phase == .running && running.content.conclusion == nil)
        try append(try event("task_complete", "t", extra: ["last_agent_message": NSNull()]), to: file)
        let finished = try reader.read().content
        #expect(finished.phase == .idle(completedTurnID: "t") && finished.conclusion == "Fixed the parser.\n\nTests pass.")
        #expect(finished.outcome == .unknown)
        // The named final message wins over the fallback, and an agent message from an earlier turn never carries over.
        try append(try event("task_started", "u") + line("event_msg", ["type": "agent_message", "message": "Interim note."])
                   + event("task_complete", "u", extra: ["last_agent_message": "Final answer."]), to: file)
        #expect(try reader.read().content.conclusion == "Final answer.")
        try append(try event("task_started", "w") + event("task_complete", "w"), to: file)
        #expect(try reader.read().content.conclusion == nil)
        try append(try event("task_started", "x") + line("event_msg", ["type": "agent_message", "message": "Partial."])
                   + event("turn_aborted", "x"), to: file)
        let aborted = try reader.read().content
        #expect(aborted.outcome == .stopped && aborted.conclusion == nil)
    }
    @Test func fileReplacementAndSymlinksAreRejectedWhileTruncationRebaselines() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "t"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file); _ = try reader.read()
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: header(first)); try handle.close()
        #expect(try reader.read().baseline)
        #expect(try reader.read().content.phase == .unknown)
        try FileManager.default.removeItem(at: file.url)
        try header(first).write(to: file.url)
        #expect(throws: CodexSessionReadFailure.self) { try reader.read() }
    }
    @Test func nativeDescriptorLookupOnlyReturnsOwnedWritableRollouts() throws {
        let (root, file) = try fixture(header(first))
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexProcessReader()
        let readOnly = try FileHandle(forReadingFrom: file.url)
        #expect(!(try reader.openRollouts(pid: getpid())).contains(file))
        let writer = try FileHandle(forWritingTo: file.url)
        #expect(try reader.openRollouts(pid: getpid()).contains(file))
        try writer.close(); try readOnly.close()
        #expect(!(try reader.openRollouts(pid: getpid())).contains(file))
    }
    @Test func unreadBacklogCannotPublishAnIntermediatePhaseAsCurrent() throws {
        let (root, file) = try fixture(header(first) + event("task_started", "old"))
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = CodexSessionReader(file: file); _ = try reader.read()
        let filler = try line("response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 1_000_000)])
        var appended = try event("task_complete", "old") + event("task_started", "new")
        for _ in 0..<5 { appended += filler }
        appended += try event("task_complete", "new")
        try append(appended, to: file)
        let bounded = try reader.read()
        #expect(bounded.content.phase == .unknown && bounded.baseline)
        let caughtUp = try reader.read()
        #expect(caughtUp.content.phase == .idle(completedTurnID: "new") && caughtUp.baseline)
    }
    @Test func commandArgumentsExcludeServersWithoutConfusingOptionValues() {
        #expect(CodexProcessReader.isInteractive(arguments: ["codex", "-m", "review", "resume", "existing"]))
        #expect(!CodexProcessReader.isInteractive(arguments: ["codex", "--config", "model=sol", "app-server", "--stdio"]))
        #expect(!CodexProcessReader.isInteractive(arguments: ["codex", "exec", "synthetic prompt"]))
        #expect(CodexProcessReader.isInteractive(arguments: ["codex", "--", "app-server"]))
    }

}
