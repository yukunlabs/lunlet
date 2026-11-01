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
