// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.03, AC-33.05, AC-33.06, AC-33.07; US-13, AC-13.01, AC-13.04; US-15, AC-15.02, AC-15.06.
// Refs: US-06, AC-06.02, AC-06.05.
import Foundation
import Testing
import LunletCore
@testable import LunletClaude

struct ClaudeTranscriptReaderTests {
    typealias F = ClaudeFixture
    private func reader(_ fixture: ClaudeFixture, _ lines: [String]) throws -> (ClaudeTranscriptReader, URL) {
        let url = try fixture.transcript(lines, session: F.first)
        return (ClaudeTranscriptReader(file: try fixture.file(url), sessionName: F.first), url)
    }

    // Refs: US-33, AC-33.03; US-13, AC-13.01.
    @Test func typedPromptRunsAndEndTurnFollowedByTurnDurationFinishes() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.ignored(), F.typed("Check  the\nbuild", uuid: "u1", prompt: "p1")])
        let started = try subject.read()
        #expect(started.baseline && started.content.phase == .running && started.content.turn == "p1")
        #expect(started.content.inputActivityID == "u1" && started.content.localPreview == "Check the build")
        // A tool round trip is not completion; neither is turn_duration without a preceding end_turn.
        try fixture.append([F.assistant(stop: "tool_use"), F.toolResult(), F.turnDuration()], to: url)
        let working = try subject.read()
        #expect(!working.baseline && working.content.phase == .running)
        try fixture.append([F.assistant(stop: "end_turn", id: "msg_2")], to: url)
        #expect(try subject.read().content.phase == .running)
        try fixture.append([F.turnDuration(at: "2026-10-30T10:00:09.000Z")], to: url)
        let finished = try subject.read()
        #expect(finished.content.phase == .idle(completedTurnID: "p1") && finished.content.outcome == .unknown)
        #expect(finished.lastActivityAt == ISO8601DateFormatter().date(from: "2026-10-30T10:00:09Z"))
        // A repeated completion record changes nothing.
        try fixture.append([F.assistant(stop: "end_turn", id: "msg_2"), F.turnDuration()], to: url)
        #expect(try subject.read().content == finished.content)
    }

    // Refs: US-33, AC-33.05, AC-33.07; US-06, AC-06.02, AC-06.05.
    @Test func theFinalReplysTextBlocksBecomeTheConclusionWithoutThinkingOrTools() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [
            F.typed("Fix the parser", uuid: "u1", prompt: "p1"),
            F.assistant(stop: "tool_use", id: "msg_1", content: [["type": "text", "text": "Let me look."],
                ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/synthetic/file"]]]),
            F.toolResult()])
        _ = try subject.read()
        // The final message arrives as one record per block: thinking, then text; a repeated record counts once.
        try fixture.append([
            F.assistant(stop: nil, id: "msg_2", content: [["type": "thinking", "thinking": "Private synthetic reasoning"]]),
            F.assistant(stop: nil, id: "msg_2", content: [["type": "text", "text": "Fixed the parser."]], uuid: "block-1"),
            F.assistant(stop: nil, id: "msg_2", content: [["type": "text", "text": "Fixed the parser."]], uuid: "block-1"),
            F.assistant(stop: "end_turn", id: "msg_2", content: [["type": "text", "text": "Tests pass."]]),
            F.assistant(stop: "end_turn", id: "msg_side", content: [["type": "text", "text": "Sidechain"]], sidechain: true),
        ], to: url)
        #expect(try subject.read().content.conclusion == nil)
        try fixture.append([F.turnDuration()], to: url)
        let finished = try subject.read().content
        #expect(finished.phase == .idle(completedTurnID: "p1") && finished.conclusion == "Fixed the parser.\n\nTests pass.")
        // A new prompt clears it, and an interruption leaves none.
        try fixture.append([F.typed("Next", uuid: "u2", prompt: "p2")], to: url)
        #expect(try subject.read().content.conclusion == nil)
        try fixture.append([F.assistant(stop: nil, id: "msg_3", content: [["type": "text", "text": "Partial"]]), F.interrupted()], to: url)
        let stopped = try subject.read().content
        #expect(stopped.outcome == .stopped && stopped.conclusion == nil)
    }

    // Refs: US-33, AC-33.05, AC-33.07; US-06, AC-06.02.
    @Test func anEndTurnWithoutTextLeavesNoConclusionAndLongRepliesAreBounded() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1"),
            F.assistant(stop: "tool_use", id: "msg_1", content: [["type": "text", "text": "Earlier commentary"]]),
            F.assistant(stop: "end_turn", id: "msg_2", content: []), F.turnDuration()])
        let empty = try subject.read().content
        #expect(empty.phase == .idle(completedTurnID: "p1") && empty.conclusion == nil)
        try fixture.append([F.typed("Second", uuid: "u2", prompt: "p2"),
                            F.assistant(stop: "end_turn", id: "msg_3", content: [["type": "text", "text": String(repeating: "é", count: 30_000)]]),
                            F.turnDuration(uuid: "c0ffee00-0000-4000-8000-000000000002")], to: url)
        let long = try #require(try subject.read().content.conclusion)
        #expect(long.utf8.count <= NoticeText.captureLimit && long.utf8.count > NoticeText.captureLimit - 2)
    }

    // Refs: US-33, AC-33.03.
    @Test func interruptionStopsTheTurnLikeACodexAbort() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("Long task", uuid: "u1", prompt: "p1"), F.assistant(stop: "tool_use")])
        _ = try subject.read()
        try fixture.append([F.interrupted()], to: url)
        let stopped = try subject.read().content
        #expect(stopped.phase == .idle(completedTurnID: "p1") && stopped.outcome == .stopped)
    }

    // Refs: US-33, AC-33.07; US-15, AC-15.02.
    @Test func injectedMetaAndToolRecordsAreNotDeveloperInput() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1"),
                                                  F.assistant(stop: "end_turn"), F.turnDuration()])
        let done = try subject.read().content
        try fixture.append([F.injected(uuid: "u2", prompt: "p2"), F.meta(uuid: "u3"), F.toolResult(),
                            F.assistant(stop: "end_turn", id: "msg_9"), F.turnDuration(uuid: "c0ffee00-0000-4000-8000-000000000009")],
                           to: url)
        let after = try subject.read().content
        #expect(after == done && after.inputActivityID == "u1" && after.localPreview == "First")
    }

    // Refs: US-33, AC-33.03.
    @Test func unknownRecordTypesAndMajorVersionsMakeStateUnknownUntilTheNextTransition() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
        _ = try subject.read()
        try fixture.append([F.line(["type": "future-record", "sessionId": F.first])], to: url)
        #expect(try subject.read().content.phase == .unknown)
        try fixture.append([F.assistant(stop: "end_turn"), F.turnDuration()], to: url)
        #expect(try subject.read().content.phase == .idle(completedTurnID: "p1"))
        try fixture.append([F.line(["type": "user", "version": "3.0.0", "sessionId": F.first, "promptSource": "typed",
                                    "uuid": "u9", "message": ["role": "user", "content": "Next"]])], to: url)
        let unsupported = try subject.read().content
        #expect(unsupported.phase == .unknown && unsupported.inputActivityID == "u1")
        #expect(ClaudeTranscriptReader.supportsVersion("2.1.306") && !ClaudeTranscriptReader.supportsVersion("20.1"))
    }

    // Refs: US-33, AC-33.03, AC-33.06.
    @Test func foreignSessionAndSidechainRecordsNeverDriveThisSession() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("Mine", uuid: "u1", prompt: "p1")])
        _ = try subject.read()
        var sidechain = try #require(JSONSerialization.jsonObject(with: Data(F.typed("Sub", uuid: "s1", prompt: "s").utf8))
                                     as? [String: Any])
        sidechain["isSidechain"] = true
        try fixture.append([F.typed("Other", uuid: "o1", prompt: "o", session: F.second), F.line(sidechain),
                            F.assistant(stop: "end_turn", session: F.second), F.turnDuration(session: F.second)], to: url)
        let content = try subject.read().content
        #expect(content.phase == .running && content.inputActivityID == "u1")
    }

    // Refs: US-33, AC-33.03, AC-33.07.
    @Test func oversizedLineIsUnknownStateNotFailureAndReadingContinues() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
        _ = try subject.read()
        let huge = F.line(["type": "attachment", "sessionId": F.first,
                           "attachment": String(repeating: "x", count: ClaudeTranscriptReader.maximumLine + 16)])
        try fixture.append([huge], to: url)
        #expect(try subject.read().content.phase == .unknown)
        try fixture.append([F.assistant(stop: "end_turn"), F.turnDuration()], to: url)
        #expect(try subject.read().content.phase == .idle(completedTurnID: "p1"))
    }

    // Refs: US-33, AC-33.03; US-02, AC-02.05. Claude Code also writes records this reader passes over when it can
    // decode them, such as an API request blob of several megabytes. One too large to decode is passed over the same
    // way when its first bytes name its type, so the turn stays as it was instead of turning unknown.
    @Test func anOversizedRecordOfATypeTheReaderPassesOverLeavesTheTurnAsItWas() throws {
        let blob = String(repeating: "x", count: ClaudeTranscriptReader.maximumLine + 16)
        for head in [#""type":"api-request-blob","sessionId":""# + F.first + #"","hash":"h""#, #""type":"attachment","promptId":"p3""#] {
          try autoreleasepool {
            let fixture = try ClaudeFixture(); defer { fixture.remove() }
            var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
            #expect(try subject.read().content.phase == .running)
            try fixture.append(["{" + head + #","message":{"role":"user","content":""# + blob + #""}}"#], to: url)
            let after = try subject.read().content
            #expect(after.phase == .running && after.turn == "p1" && after.localPreview == "First")
            try fixture.append([F.assistant(stop: "end_turn"), F.turnDuration()], to: url)
            #expect(try subject.read().content.phase == .idle(completedTurnID: "p1"))
          }
        }
        // A record the reader acts on, or one whose type the first bytes do not show, still leaves the state unknown.
        for head in [#""type":"assistant","sessionId":""# + F.first + #"""#, #""sessionId":""# + F.first + #"""#] {
          try autoreleasepool {
            let fixture = try ClaudeFixture(); defer { fixture.remove() }
            var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
            _ = try subject.read()
            try fixture.append(["{" + head + #","message":{"role":"assistant","content":""# + blob + #""},"type":"assistant"}"#], to: url)
            #expect(try subject.read().content.phase == .unknown)
          }
        }
    }

    // Refs: US-33, AC-33.03, AC-33.05; US-13, AC-13.04; US-06, AC-06.02. A prompt with pasted screenshots can exceed the
    // line bound. Its content is not read, but the members before and after it name the record, so the turn still
    // begins under its own id; otherwise the previous turn's id would complete a second time and no notice would go
    // out. The members may sit on either side of the oversized one.
    @Test func anOversizedTypedPromptStillStartsItsOwnTurn() throws {
        // Each case builds megabytes of text; a pool per case keeps them from adding up in the test process.
        for idsFirst in [true, false] { try autoreleasepool {
            let fixture = try ClaudeFixture(); defer { fixture.remove() }
            var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1"), F.assistant(stop: "end_turn"), F.turnDuration()])
            #expect(try subject.read().content.phase == .idle(completedTurnID: "p1"))
            let image = String(repeating: "A", count: ClaudeTranscriptReader.maximumLine + 16)
            let message = #""message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":""# + image
                + #""}},{"type":"text","text":"What is in this \"picture\"?"}]}"#
            let ids = #""parentUuid":null,"isSidechain":false,"promptId":"p2","type":"user","origin":{"kind":"human"},"#
                + #""promptSource":"typed","turnOrigin":"human","uuid":"u2","timestamp":"2026-10-30T10:01:00.000Z","#
                + #""sessionId":""# + F.first + #"","version":"2.1.314""#
            try fixture.append(["{" + (idsFirst ? ids + "," + message : message + "," + ids) + "}"], to: url)
            let started = try subject.read()
            #expect(started.content.phase == .running && started.content.turn == "p2" && started.content.inputActivityID == "u2")
            // The request's text was not read, so the earlier request is not shown in its place.
            #expect(started.content.localPreview == nil && started.content.conclusion == nil)
            #expect(started.lastActivityAt == ISO8601DateFormatter().date(from: "2026-10-30T10:01:00Z"))
            try fixture.append([F.assistant(stop: "end_turn", id: "msg_2", content: [["type": "text", "text": "A cat"]]),
                                F.turnDuration(uuid: "c0ffee00-0000-4000-8000-000000000002", at: "2026-10-30T10:01:09.000Z")], to: url)
            let finished = try subject.read().content
            #expect(finished.phase == .idle(completedTurnID: "p2") && finished.conclusion == "A cat")
        } }
        // An oversized record that is not a typed prompt of this session starts nothing: a tool result of the same
        // turn, an injected prompt, another session's record.
        for members in [#""type":"user","promptId":"p1","turnOrigin":"human""#, #""type":"user","promptId":"p3","promptSource":"system""#,
                        #""type":"user","promptId":"p3","turnOrigin":"human","sessionId":""# + F.second + #"""#,
                        #""type":"user","promptId":"p3","turnOrigin":"human","isSidechain":true"#] {
          try autoreleasepool {
            let fixture = try ClaudeFixture(); defer { fixture.remove() }
            var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
            _ = try subject.read()
            let blob = String(repeating: "x", count: ClaudeTranscriptReader.maximumLine + 16)
            try fixture.append(["{" + members + #","message":{"role":"user","content":""# + blob + #""}}"#], to: url)
            let after = try subject.read().content
            #expect(after.phase == .unknown && after.turn == "p1" && after.localPreview == "First")
          }
        }
    }

    // Refs: US-33, AC-33.03; US-13, AC-13.04.
    @Test func appendResumesAtLineBoundariesAndReplacementIsRejected() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var (subject, url) = try reader(fixture, [F.typed("First", uuid: "u1", prompt: "p1")])
        _ = try subject.read()
        // A partially written record waits for its newline.
        let partial = F.assistant(stop: "end_turn") + "\n" + F.turnDuration()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(partial.utf8)); try handle.close()
        #expect(try subject.read().content.phase == .running)
        try fixture.append([""], to: url)
        let finished = try subject.read()
        #expect(!finished.baseline && finished.content.phase == .idle(completedTurnID: "p1"))
        try FileManager.default.removeItem(at: url)
        try fixture.transcript([F.typed("Replaced", uuid: "r1", prompt: "r")], session: F.first)
        #expect(throws: (any Error).self) { try subject.read() }
    }
}
