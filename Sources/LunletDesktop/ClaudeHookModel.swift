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
    @Published private(set) var actionIssue: ClaudeHookFailure?

    private let service: ClaudeHookConnection
    private let connectsAutomatically: Bool
    private var active = false
    private var generation = 0

    init(service: ClaudeHookConnection = .init(), connectsAutomatically: Bool = false) {
        self.service = service; self.connectsAutomatically = connectsAutomatically
    }
    static let placeholder = ClaudeHookModel()

    /// Work happens only while Claude Code is a selected agent; turning it off takes Lunlet's hook out again.
    func setActive(_ value: Bool) {
        active = value
        if value { change { try $0.connect() } }
        else if connectsAutomatically { change { try $0.disconnect() } }
    }
    /// Settings shows the connection whether or not Claude Code is a selected agent.
    func refresh() { change { try $0.state() } }
    /// After a failure, the connect is attempted again on request.
    func retry() {
        let connects = active
        change { connects ? try $0.connect() : try $0.state() }
    }

    private func change(_ action: @escaping @Sendable (ClaudeHookConnection) throws -> ClaudeHookState) {
        guard connectsAutomatically || !active else { return }
        generation += 1
        let current = generation, service = service
        Task.detached(priority: .utility) {
            let outcome = Result { try action(service) }
            await MainActor.run { [weak self] in
                guard let self, generation == current else { return }
                switch outcome {
                case .success(let state):
                    connection = state == .connected ? .connected : .notConnected
                    actionIssue = nil
                case .failure(let error):
                    let failure = (error as? ClaudeHookFailure) ?? .writeFailed
                    if case .claudeDirectoryMissing = failure { connection = .unavailable(failure) } else { actionIssue = failure }
                }
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
