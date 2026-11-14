// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08; US-31, AC-31.02; US-04, AC-04.03; US-24, AC-24.02.
import LunletClaude
import SwiftUI

/// No switch of its own: the Claude Code agent switch decides, connecting Lunlet's status line while Claude Code is
/// selected and restoring the previous one when it is not (AC-33.08). Settings › Agents shows the connection as one
/// status word, and as a note with its action when something needs the owner's attention, such as a status line
/// changed outside Lunlet.
struct ClaudePlanLimitsSettings: View {
    @ObservedObject var model: ClaudePlanLimitsModel

    var body: some View {
        let status = Self.status(connection: model.connection, issue: model.actionIssue)
        SettingsStatusRow(title: "Plan limits", status: status,
                          actionHelp: status.action == .forget
                            ? "Lunlet stops tracking its earlier connection and leaves Claude Code's settings unchanged." : nil) { action in
            switch action {
            case .forget: model.forget()
            case .retry: model.retry()
            }
        }
    }

    /// The connection in words. A change that failed keeps its note whatever the connection reads, with Try again;
    /// a line changed outside Lunlet offers Forget, also beside such a note; an unreadable setup says why and
    /// offers nothing.
    static func status(connection: ClaudePlanLimitsModel.Connection, issue: ClaudeStatusLineFailure?) -> SettingsStatus {
        if let issue {
            return .init(text: message(issue), tone: .attention, action: connection == .changedOutsideLunlet ? .forget : .retry)
        }
        switch connection {
        case .checking: return .init(text: "Checking…", tone: .neutral, action: nil)
        case .notConnected: return .init(text: "Not connected", tone: .neutral, action: nil)
        case .connected: return .init(text: "Status line connected", tone: .success, action: nil)
        case .changedOutsideLunlet:
            return .init(text: "Claude Code's status line was changed after Lunlet connected; Lunlet leaves it alone.",
                         tone: .attention, action: .forget)
        case .unavailable(let failure): return .init(text: message(failure), tone: .attention, action: nil)
        }
    }

    static func message(_ failure: ClaudeStatusLineFailure) -> String {
        switch failure {
        case .claudeDirectoryMissing: "Claude Code's settings folder was not found; run Claude Code once, then try again."
        case .settingsUnreadable: "Claude Code's settings could not be read; nothing was changed."
        case .settingsInvalid: "Claude Code's settings are not valid JSON; Lunlet left them unchanged."
        case .unsupportedStatusLine: "The existing status line is not a command Lunlet can keep running; nothing was changed."
        case .settingsChanged: "Claude Code's settings changed while Lunlet was editing them; nothing was changed. Try again."
        case .storageUnavailable: "Lunlet's own folder could not be prepared; nothing was changed."
        case .writeFailed: "Claude Code's settings could not be saved; nothing was changed."
        }
    }
}
