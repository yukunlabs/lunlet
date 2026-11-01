// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08; US-31, AC-31.02; US-04, AC-04.03.
import LunletClaude
import SwiftUI

/// No switch of its own: the Claude Code agent switch decides, connecting Lunlet's status line while Claude Code is
/// selected and restoring the previous one when it is not (AC-33.08). Settings › Agents shows a note here only when
/// something needs the owner's attention, such as a status line changed outside Lunlet.
struct ClaudePlanLimitsSettings: View {
    @ObservedObject var model: ClaudePlanLimitsModel

    var body: some View {
        if let note {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.small) {
                    Text(note).font(Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.connection == .changedOutsideLunlet {
                        Button("Forget", action: model.forget).controlSize(.small)
                            .help("Lunlet stops tracking its earlier connection and leaves Claude Code's settings unchanged.")
                    } else if model.actionIssue != nil {
                        Button("Try again", action: model.connect).controlSize(.small)
                    }
                }
            } header: {
                Text("Claude Code plan limits")
            }
        }
    }

    /// Text appears only when something needs the owner's attention.
    private var note: String? {
        if let issue = model.actionIssue { return Self.message(issue) }
        switch model.connection {
        case .changedOutsideLunlet: return "Claude Code's status line was changed after Lunlet connected; Lunlet leaves it alone."
        case .unavailable(let failure): return Self.message(failure)
        default: return nil
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
