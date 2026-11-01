// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.11; US-04, AC-04.03.
import Foundation
import Testing
@testable import LunletClaude

/// Synthetic profiles only; no real account data.
@Suite struct ClaudeAccountProfileTests {
    private func profile(_ account: String) -> ClaudeAccountProfile? {
        ClaudeAccountProfile.decode(Data(#"{"projects":{"/tmp/x":{"history":["kept private"]}},"oauthAccount":"#.utf8)
            + Data(account.utf8) + Data("}".utf8))
    }

    // Refs: US-33, AC-33.11.
    @Test func keepsOnlyTheEmailAndAKnownPlan() {
        let max = profile(#"{"emailAddress":"owner@example.invalid","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","accountUuid":"synthetic"}"#)
        #expect(max == .init(email: "owner@example.invalid", plan: "Max 20x"))
        #expect(ClaudeAccountProfile.plan(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeAccountProfile.plan(organizationType: "claude_max", rateLimitTier: nil) == "Max")
        #expect(ClaudeAccountProfile.plan(organizationType: "claude_pro", rateLimitTier: "default_claude_ai") == "Pro")
        // An unrecognized plan is left out rather than guessed; a malformed email is dropped.
        #expect(profile(#"{"emailAddress":"owner@example.invalid","organizationType":"something_new"}"#)
            == .init(email: "owner@example.invalid", plan: nil))
        #expect(profile(#"{"emailAddress":"not an email","organizationType":"claude_pro"}"#) == .init(email: nil, plan: "Pro"))
    }

    // Refs: US-33, AC-33.11; US-04, AC-04.03.
    @Test func missingOrUnusableProfilesAreUnknown() throws {
        #expect(profile(#"{}"#) == nil && profile(#"{"emailAddress":"x"}"#) == nil)
        #expect(ClaudeAccountProfile.decode(Data(#"{"projects":{}}"#.utf8)) == nil)
        #expect(ClaudeAccountProfile.decode(Data("not json".utf8)) == nil)
        // A relocated configuration root keeps its profile inside the root; a missing file reads as unknown.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-profile-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ClaudeHome(root: root)
        #expect(home.profile == root.appendingPathComponent(".claude.json") && ClaudeAccountProfile.read(home: home) == nil)
        try Data(#"{"oauthAccount":{"emailAddress":"owner@example.invalid","organizationType":"claude_team"}}"#.utf8)
            .write(to: home.profile)
        #expect(ClaudeAccountProfile.read(home: home) == .init(email: "owner@example.invalid", plan: "Team"))
    }
}
