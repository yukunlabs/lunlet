// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.06; US-31, AC-31.02; US-33, AC-33.08.
import Foundation
import LunletClaude
import SwiftUI

/// Lunlet's Stop hook in Claude Code's settings: connected while Claude Code is a selected agent and removed when it
/// is turned off, like the status line (AC-33.08). There is no switch of its own; Settings shows a note only when
/// Claude Code's settings cannot be changed (AC-38.06).
@MainActor final class ClaudeHookModel: ObservableObject {
    enum Connection: Equatable, Sendable {
        case checking, notConnected, connected
        case unavailable(ClaudeHookFailure)
    }
    @Published private(set) var connection = Connection.checking
    /// Why the last change to Claude Code's settings did not happen; it stays until that change succeeds, or the
    /// file is seen in the state the change was meant to leave.
    @Published private(set) var actionIssue: ClaudeHookFailure?

    /// The two changes this owner makes; a failure keeps the one it was, so Try again repeats it (AC-38.06).
    private enum Change: Sendable { case connect, remove }

    private let service: ClaudeHookConnection
    private let connectsAutomatically: Bool
    private var active = false
    /// Counts changes: a change's outcome is published only while it is the latest, and a state read that began
    /// before a change never replaces what the change found.
    private var changes = 0
    private var failedChange: Change?
    /// Work runs in the order it was asked for, so turning Claude Code off and on again ends with the hook in place.
    private var work: Task<Void, Never>?

    init(service: ClaudeHookConnection = .init(), connectsAutomatically: Bool = false) {
        self.service = service; self.connectsAutomatically = connectsAutomatically
    }
    static let placeholder = ClaudeHookModel()

    /// Work happens only while Claude Code is a selected agent; turning it off takes Lunlet's hook out again.
    func setActive(_ value: Bool) {
        active = value
        perform(value ? .connect : .remove)
    }
    /// Settings shows the connection whether or not Claude Code is a selected agent. Reading it says nothing about
    /// a change that failed, so the note stays.
    func refresh() { readState() }
    /// Repeats the change that failed: the connect, or the removal after Claude Code was turned off.
    func retry() {
        if let failedChange { perform(failedChange) } else if active { perform(.connect) } else { readState() }
    }

    private func perform(_ change: Change) {
        guard connectsAutomatically else { return }
        changes += 1
        let current = changes, service = service, previous = work
        work = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) {
                Result { change == .connect ? try service.connect() : try service.disconnect() }
            }.value
            guard let self, self.changes == current else { return }
            switch outcome {
            case .success(let state):
                self.connection = state == .connected ? .connected : .notConnected
                self.actionIssue = nil; self.failedChange = nil
            case .failure(let error):
                let failure = (error as? ClaudeHookFailure) ?? .writeFailed
                if case .claudeDirectoryMissing = failure { self.connection = .unavailable(failure) } else { self.actionIssue = failure }
                self.failedChange = change
            }
        }
    }

    private func readState() {
        guard connectsAutomatically || !active else { return }
        let started = changes, service = service, previous = work
        work = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) { Result { try service.state() } }.value
            guard let self, self.changes == started else { return }
            switch outcome {
            case .success(let state):
                self.connection = state == .connected ? .connected : .notConnected
                // The note goes only when the file already shows what the failed change was meant to do.
                if let failed = self.failedChange, (failed == .connect) == (state == .connected) {
                    self.actionIssue = nil; self.failedChange = nil
                }
            case .failure(let error):
                let failure = (error as? ClaudeHookFailure) ?? .settingsUnreadable
                if case .claudeDirectoryMissing = failure { self.connection = .unavailable(failure) }
                else if self.failedChange == nil { self.actionIssue = failure }
            }
        }
    }
}

private struct ClaudeHookKey: EnvironmentKey { static let defaultValue: ClaudeHookModel? = nil }
extension EnvironmentValues {
    /// The runtime's Claude hook owner; nil in previews and tests that do not show it.
    var claudeHook: ClaudeHookModel? {
        get { self[ClaudeHookKey.self] }
        set { self[ClaudeHookKey.self] = newValue }
    }
}
