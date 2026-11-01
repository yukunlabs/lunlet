// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04; US-24, AC-24.03; US-12, AC-12.05.
import AppKit
import Testing
@testable import LunletDesktop

/// The channel setup's token fields take Cmd-V, Cmd-C, Cmd-X, Cmd-A and Cmd-Z only through the main menu's Edit
/// items, which an accessory app must supply itself; Quit stays on Cmd-Q.
@MainActor struct ApplicationMenuTests {
    @Test func theMainMenuRoutesTheStandardEditKeysAndQuit() throws {
        let menu = ApplicationMenu.make()
        let edit = try #require(menu.item(withTitle: "Edit")?.submenu)
        let expected: [(String, String, Selector)] = [
            ("Cut", "x", #selector(NSText.cut(_:))), ("Copy", "c", #selector(NSText.copy(_:))),
            ("Paste", "v", #selector(NSText.paste(_:))), ("Select All", "a", #selector(NSText.selectAll(_:))),
        ]
        for (title, key, action) in expected {
            let item = try #require(edit.item(withTitle: title))
            // No target: the focused field editor answers through the responder chain.
            #expect(item.keyEquivalent == key && item.keyEquivalentModifierMask == [.command] && item.action == action && item.target == nil)
        }
        #expect(edit.item(withTitle: "Undo")?.keyEquivalent == "z")
        #expect(edit.item(withTitle: "Redo")?.keyEquivalentModifierMask == [.command, .shift])
        let quit = try #require(menu.item(withTitle: "Lunlet")?.submenu?.item(withTitle: "Quit"))
        #expect(quit.keyEquivalent == "q" && quit.action == #selector(NSApplication.terminate(_:)))
    }
}
