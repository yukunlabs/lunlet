// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.06; US-31, AC-31.02; US-33, AC-33.08; US-24, AC-24.02.
import LunletClaude
import SwiftUI

/// No switch of its own: the Claude Code agent switch decides, adding Lunlet's Stop hook while Claude Code is selected
/// and removing it when it is not. Settings › Agents shows the hook as one status word, and as a note with a way to
/// try again when Claude Code's settings could not be changed (AC-38.06).
struct ClaudeHookSettings: View {
    @ObservedObject var model: ClaudeHookModel

    var body: some View {
        let status = Self.status(connection: model.connection, issue: model.actionIssue)
        SettingsStatusRow(title: "Phone replies", status: status) { _ in model.retry() }
            // A note is rechecked when it is shown; a healthy state is the runtime's own.
            .onAppear { if status.needsAttention { model.refresh() } }
    }

    /// The hook in words. A change that failed keeps its note and Try again whatever the connection reads; a missing
    /// Claude Code folder says why and offers nothing.
    static func status(connection: ClaudeHookModel.Connection, issue: ClaudeHookFailure?) -> SettingsStatus {
        if let issue { return .init(text: message(issue), tone: .attention, action: .retry) }
        switch connection {
        case .checking: return .init(text: "Checking…", tone: .neutral, action: nil)
        case .notConnected: return .init(text: "Not added", tone: .neutral, action: nil)
        case .connected: return .init(text: "Stop hook added", tone: .success, action: nil)
        case .unavailable(let failure): return .init(text: message(failure), tone: .attention, action: nil)
        }
    }

    static func message(_ failure: ClaudeHookFailure) -> String {
        switch failure {
        case .claudeDirectoryMissing: "Claude Code's settings folder was not found, so phone replies to Claude Code are off; run Claude Code once, then try again."
        case .settingsUnreadable: "Claude Code's settings could not be read, so its Stop hook for phone replies was not added."
        case .settingsInvalid: "Claude Code's settings are not a JSON object with hook lists; Lunlet left them unchanged and phone replies to Claude Code are off."
        case .settingsChanged: "Claude Code's settings changed while Lunlet was editing them; nothing was changed. Try again."
        case .storageUnavailable: "Lunlet's own folder could not be prepared, so its Stop hook was not added."
        case .writeFailed: "Claude Code's settings could not be saved, so its Stop hook for phone replies was not added."
        }
    }
}
