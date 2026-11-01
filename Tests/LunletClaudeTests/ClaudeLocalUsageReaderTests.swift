// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.04, AC-33.06, AC-33.07, AC-33.10; US-04, AC-04.02, AC-04.03; US-18, AC-18.01, AC-18.03.
import Foundation
import Testing
import LunletCore
@testable import LunletClaude

struct ClaudeLocalUsageReaderTests {
    typealias F = ClaudeFixture
    let now = Date(timeIntervalSince1970: 1_793_390_400)  // 2026-10-30T20:00:00Z
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    let first = UUID(uuidString: F.first)!

    // Refs: US-33, AC-33.04, AC-33.06.
    @Test func eachResponseCountsOnceAcrossContentBlocksAndSubagentFiles() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let usage = F.usage(input: 10, write5m: 100, write1h: 20, read: 1_000, output: 50)
        // One response is written once per content block; a subagent transcript repeats it and adds its own.
        try fixture.transcript([F.typed("A", uuid: "u1", prompt: "p1"), F.assistant(stop: "tool_use", id: "msg_a", usage: usage),
                                F.assistant(stop: "tool_use", id: "msg_a", usage: usage)], session: F.first)
        try fixture.subagent([F.assistant(stop: "tool_use", id: "msg_a", usage: usage),
                              F.assistant(stop: "end_turn", id: "msg_b", usage: F.usage(input: 1, write5m: 0, read: 0, output: 9))],
                             session: F.first)
        let history = try await ClaudeLocalUsageReader(home: fixture.home).readHistory(now: now, calendar: calendar, days: 1)
        let session = try #require(history.sessions[first])
        #expect(history.sessions.count == 1)
        let expectedTokens: Int64 = 1_180 + 10
        #expect(session.tokens == expectedTokens)
        // Opus 5.5: $4 input, $5 5m writes, $8 1h writes, $0.20 reads, $20 output per million tokens.
        let expected = (10 * 4 + 100 * 5 + 20 * 8 + 1_000 * 0.20 + 50 * 20 + 1 * 4 + 9 * 20) / 1_000_000.0
        #expect(abs((session.estimatedUSD ?? 0) - expected) < 1e-12)
        // Transcripts omit some usage: every amount is a labelled lower bound.
        #expect(session.partial && session.costPartial && history.partial)
        #expect(history.days.count == 1 && history.days[0].amount.tokens == 1_190)
        // Refs: US-33, AC-33.10. Categories stay separate, so cache reads never hide in one total.
        let categories = LocalTokenBreakdown(input: 11, output: 59, cacheWrite: 120, cacheRead: 1_000)
        #expect(session.breakdown == categories && history.days[0].amount.breakdown == categories)
    }

    // Refs: US-33, AC-33.04; US-04, AC-04.02, AC-04.03.
    @Test func unknownModelsAndOmittedModifiersStayUnpricedWhileKnownSubtotalsRemain() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        var unclassified = F.usage(input: 5, write5m: 0, read: 0, output: 5)
        unclassified["cache_creation"] = nil; unclassified["cache_creation_input_tokens"] = 40
        try fixture.transcript([
            F.assistant(stop: "end_turn", id: "msg_known", usage: F.usage(input: 100, write5m: 0, read: 0, output: 0)),
            F.assistant(stop: "end_turn", id: "msg_unknown", model: "claude-future-9",
                        usage: F.usage(input: 7, write5m: 0, read: 0, output: 3)),
            F.assistant(stop: "end_turn", id: "msg_fast", usage: F.usage(input: 11, write5m: 0, read: 0, output: 0, speed: "fast")),
            F.assistant(stop: "end_turn", id: "msg_geo", usage: F.usage(input: 13, write5m: 0, read: 0, output: 0, geo: "eu")),
            F.assistant(stop: "end_turn", id: "msg_writes", usage: unclassified),
        ], session: F.first)
        let history = try await ClaudeLocalUsageReader(home: fixture.home).readHistory(now: now, calendar: calendar, days: 1)
        let session = try #require(history.sessions[first])
        let expectedTokens: Int64 = 100 + 10 + 11 + 13 + 50  // known, unknown model, fast, other geography, writes
        #expect(session.tokens == expectedTokens)
        #expect(session.pricedTokens == 100 && session.unpricedTokens == 84)
        #expect(abs((session.estimatedUSD ?? 0) - 100 * 4 / 1_000_000.0) < 1e-12)
    }

    // Refs: US-33, AC-33.04.
    @Test func publishedTiersAndMultipliersAreAppliedExactly() {
        let counts = ClaudeTokenCounts(input: 1_000_000)
        #expect(ClaudePricing.cost(counts, key: .init(model: "claude-sonnet-5-5", inferenceGeo: nil, speed: nil, serviceTier: nil)) == 2)
        let us = ClaudePricing.cost(counts, key: .init(model: "claude-sonnet-5-5", inferenceGeo: "us", speed: "standard",
                                                       serviceTier: "standard"))
        #expect(abs((us ?? 0) - 2.2) < 1e-12)
        // Haiku 5.5 prices a prompt over 100,000 tokens, cache reads included, at its higher tier.
        let small = ClaudeTokenCounts(input: 50_000, cacheRead: 50_000, output: 1_000)
        let large = ClaudeTokenCounts(input: 50_000, cacheRead: 50_001, output: 1_000)
        let haiku = ClaudePricingKey(model: "claude-haiku-5-5", inferenceGeo: "global", speed: nil, serviceTier: nil)
        #expect(abs((ClaudePricing.cost(small, key: haiku) ?? 0) - (50_000 * 0.10 + 50_000 * 0.01 + 1_000 * 0.50) / 1e6) < 1e-12)
        #expect(abs((ClaudePricing.cost(large, key: haiku) ?? 0) - (50_000 * 0.50 + 50_001 * 0.05 + 1_000 * 2.50) / 1e6) < 1e-12)
        // Pre-4.6 models have no US-only multiplier; aliases and priority tiers are not guessed.
        #expect(ClaudePricing.cost(counts, key: .init(model: "claude-haiku-4-5-20251001", inferenceGeo: "us", speed: nil,
                                                      serviceTier: nil)) == nil)
        #expect(ClaudePricing.cost(counts, key: .init(model: "claude-haiku-4-5", inferenceGeo: nil, speed: nil, serviceTier: nil)) == nil)
        #expect(ClaudePricing.cost(counts, key: .init(model: "claude-opus-5-5", inferenceGeo: nil, speed: nil,
                                                      serviceTier: "priority")) == nil)
    }

    // Refs: US-33, AC-33.04; US-18, AC-18.01, AC-18.03.
    @Test func appendedTranscriptsResumeAndOversizedLinesOnlyMarkCoverage() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let url = try fixture.transcript([F.assistant(stop: "end_turn", id: "msg_1",
                                                      usage: F.usage(input: 1, write5m: 0, read: 0, output: 1))], session: F.first)
        let reader = ClaudeLocalUsageReader(home: fixture.home)
        #expect(try await reader.readHistory(now: now, calendar: calendar, days: 3).sessions[first]?.tokens == 2)
        let huge = F.line(["type": "assistant", "padding": String(repeating: "x", count: 2_097_200)])
        try fixture.append([huge, F.assistant(stop: "end_turn", id: "msg_2", usage: F.usage(input: 3, write5m: 0, read: 0, output: 4),
                                              at: "2026-10-29T12:00:00.000Z")], to: url)
        let resumed = try await reader.readHistory(now: now, calendar: calendar, days: 3)
        #expect(resumed.sessions[first]?.tokens == 9)
        #expect(resumed.days.map { $0.amount.tokens } == [nil, 7, 2])
        await #expect(throws: LocalUsageReadFailure.invalidRange) { try await reader.readHistory(now: now, calendar: calendar, days: 8) }
    }

    // Refs: US-33, AC-33.07.
    @Test func onlySessionAndSubagentTranscriptsAreRead() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        try fixture.transcript([F.assistant(stop: "end_turn", id: "msg_1", usage: F.usage(input: 1, write5m: 0, read: 0, output: 1))],
                               session: F.first)
        let decoy = [F.assistant(stop: "end_turn", id: "msg_decoy", usage: F.usage(input: 500, write5m: 0, read: 0, output: 500))]
        let project = fixture.projectDirectory()
        for path in ["\(F.first)/tool-results/result.jsonl", "memory/notes.jsonl", "\(F.first)/subagents/notes.jsonl",
                     "history.jsonl", "\(F.first)/subagents/agent-a1.meta.json"] {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(decoy.map { $0 + "\n" }.joined().utf8).write(to: url)
        }
        try Data(decoy.map { $0 + "\n" }.joined().utf8).write(to: fixture.root.appendingPathComponent("history.jsonl"))
        let history = try await ClaudeLocalUsageReader(home: fixture.home).readHistory(now: now, calendar: calendar, days: 1)
        #expect(history.sessions.count == 1 && history.sessions[first]?.tokens == 2)
        let missing = ClaudeLocalUsageReader(home: .init(root: fixture.root.appendingPathComponent("absent")))
        await #expect(throws: LocalUsageReadFailure.unavailable) { try await missing.readHistory(now: now, calendar: calendar, days: 1) }
    }
}
