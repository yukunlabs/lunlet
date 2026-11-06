// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.06; US-31, AC-31.02; US-33, AC-33.08.
import LunletClaude
import SwiftUI

/// No switch of its own: the Claude Code agent switch decides, adding Lunlet's Stop hook while Claude Code is selected
/// and removing it when it is not. Settings › Agents shows a note here only when Claude Code's settings could not be
/// changed, with a way to try again (AC-38.06).
struct ClaudeHookSettings: View {
    @ObservedObject var model: ClaudeHookModel

    var body: some View {
        if let note {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.small) {
                    Text(note).font(Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.actionIssue != nil {
                        Button("Try again", action: model.retry).controlSize(.small)
                    }
                }
            } header: {
                Text("Claude Code phone replies")
            }
            .onAppear(perform: model.refresh)
        }
    }

    /// Text appears only when something needs the owner's attention.
    private var note: String? {
        if let issue = model.actionIssue { return Self.message(issue) }
        if case .unavailable(let failure) = model.connection { return Self.message(failure) }
        return nil
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
