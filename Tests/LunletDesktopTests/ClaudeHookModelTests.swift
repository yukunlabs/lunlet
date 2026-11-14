// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.06; US-33, AC-33.08.
// The owners of Lunlet's two entries in Claude Code's settings, when a change fails or changes overlap.
// Synthetic settings in per-test temporary directories only.
import Darwin
import Foundation
import Testing
import LunletHook
@testable import LunletClaude
@testable import LunletDesktop

@MainActor struct ClaudeSettingsOwnersFixture {
    let root: URL
    var claude: URL { root.appendingPathComponent("claude", isDirectory: true) }
    var settings: URL { claude.appendingPathComponent("settings.json") }
    /// A file here keeps Lunlet's own folders from being made.
    var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    var hook: ClaudeHookConnection { .init(home: .init(root: claude), spool: .init(root: support.appendingPathComponent("hook"))) }
    var statusLine: ClaudeStatusLineConnection {
        .init(home: .init(root: claude), location: .init(directory: support.appendingPathComponent("status-line")))
    }
    static let original = "{\n  \"theme\": \"dark\"\n}\n"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-settings-owners-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try Data(Self.original.utf8).write(to: root.appendingPathComponent("claude/settings.json"))
    }
    var text: String? { try? String(contentsOf: settings, encoding: .utf8) }
    /// The settings folder read-only: the file can be read but a change cannot be saved.
    func lockSettings(_ locked: Bool) { chmod(claude.path, locked ? 0o500 : 0o700) }
    func remove() { lockSettings(false); try? FileManager.default.removeItem(at: root) }
    static func settle(until done: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor @Suite struct ClaudeHookModelTests {
    typealias Fixture = ClaudeSettingsOwnersFixture

    // Refs: US-38, AC-38.06. The note with Try again stays until the hook is in place: opening Settings reads the
    // state, and that read succeeding says nothing about the change that failed.
    @Test func aFailedConnectKeepsItsNoteThroughAStateReadAndTryAgainConnects() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try Data().write(to: fixture.support)
        let model = ClaudeHookModel(service: fixture.hook, connectsAutomatically: true)
        model.setActive(true)
        try await Fixture.settle { model.actionIssue != nil }
        #expect(model.actionIssue == .storageUnavailable)
        model.refresh()
        try await Fixture.settle { model.connection == .notConnected }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.connection == .notConnected && model.actionIssue == .storageUnavailable)
        // The cause is gone; Try again adds the hook and the note goes.
        try FileManager.default.removeItem(at: fixture.support)
        model.retry()
        try await Fixture.settle { model.connection == .connected }
        #expect(model.connection == .connected && model.actionIssue == nil)
        #expect(try fixture.hook.state() == .connected)
    }

    // Refs: US-38, AC-38.01, AC-38.06. Turning Claude Code off must take the hook out; when that could not be saved,
    // Try again repeats the removal instead of only reading the state and dropping the note.
    @Test func tryAgainRepeatsAFailedRemoval() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = ClaudeHookModel(service: fixture.hook, connectsAutomatically: true)
        model.setActive(true)
        try await Fixture.settle { model.connection == .connected }
        fixture.lockSettings(true)
        model.setActive(false)
        try await Fixture.settle { model.actionIssue != nil }
        #expect(model.actionIssue == .writeFailed)
        #expect(try fixture.hook.state() == .connected)
        model.refresh()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.actionIssue == .writeFailed && model.connection == .connected)
        fixture.lockSettings(false)
        model.retry()
        try await Fixture.settle { model.connection == .notConnected && model.actionIssue == nil }
        #expect(model.connection == .notConnected && model.actionIssue == nil)
        #expect(fixture.text == Fixture.original)
    }

    // Refs: US-38, AC-38.01. Off and on in quick succession ends with what was asked last, whichever change's
    // background work happens to run first.
    @Test func changesTakeEffectInTheOrderTheyWereAskedFor() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = ClaudeHookModel(service: fixture.hook, connectsAutomatically: true)
        for _ in 0..<20 {
            model.setActive(true); model.setActive(false); model.setActive(true)
            try await Fixture.settle { model.connection == .connected }
            try await Task.sleep(for: .milliseconds(20))
            #expect(try fixture.hook.state() == .connected)
            model.setActive(false)
            try await Fixture.settle { model.connection == .notConnected }
            try await Task.sleep(for: .milliseconds(20))
            #expect(fixture.text == Fixture.original)
        }
    }
}

@MainActor @Suite struct ClaudePlanLimitsModelTests {
    typealias Fixture = ClaudeSettingsOwnersFixture
    private func choices() throws -> (UserDefaults, String) {
        return try ScratchSettings.make("claude-limits-owner")
    }

    // Refs: US-33, AC-33.08. Turning Claude Code off restores the previous status line; when that could not be saved,
    // Try again repeats the removal. It used to connect instead, and the removal was never attempted again.
    @Test func tryAgainRepeatsAFailedRemovalOfTheStatusLine() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let (choices, suite) = try choices(); defer { choices.removePersistentDomain(forName: suite) }
        let model = ClaudePlanLimitsModel(service: fixture.statusLine, connectsAutomatically: true, choices: choices)
        model.setActive(true)
        try await Fixture.settle { model.connection == .connected && !model.isChanging }
        #expect(fixture.text?.contains("\"statusLine\"") == true)
        fixture.lockSettings(true)
        model.setActive(false)
        try await Fixture.settle { model.actionIssue != nil && !model.isChanging }
        #expect(model.actionIssue == .writeFailed && fixture.text?.contains("\"statusLine\"") == true)
        fixture.lockSettings(false)
        model.retry()
        try await Fixture.settle { fixture.text == Fixture.original && !model.isChanging }
        #expect(fixture.text == Fixture.original && model.actionIssue == nil && model.connection == .notConnected)
        await model.shutdown()
    }

    // Refs: US-33, AC-33.08. Claude Code turned off while the automatic connect is still being written: the removal
    // waits for that change and then runs. It used to be dropped, leaving Lunlet's status line in place for good.
    @Test func turningClaudeCodeOffDuringAChangeStillRemovesTheStatusLine() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let (choices, suite) = try choices(); defer { choices.removePersistentDomain(forName: suite) }
        let gate = DispatchSemaphore(value: 0)
        var service = fixture.statusLine
        // Holds each change between its read and its write until the test lets it go on.
        service.afterRead = { gate.wait() }
        let model = ClaudePlanLimitsModel(service: service, connectsAutomatically: true, choices: choices)
        model.setActive(true)
        try await Fixture.settle { model.isChanging }
        #expect(model.isChanging)
        model.setActive(false)
        for _ in 0..<16 { gate.signal() }
        try await Fixture.settle { fixture.text == Fixture.original && !model.isChanging }
        #expect(fixture.text == Fixture.original && model.connection == .notConnected)
        // Selecting it again connects again.
        model.setActive(true)
        try await Fixture.settle { model.connection == .connected && !model.isChanging }
        #expect(fixture.text?.contains("\"statusLine\"") == true)
        model.setActive(false)
        try await Fixture.settle { fixture.text == Fixture.original && !model.isChanging }
        #expect(fixture.text == Fixture.original)
        await model.shutdown()
    }
}
