// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04; US-24, AC-24.03; US-12, AC-12.05; US-39, AC-39.07.
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

    private final class MenuTarget: NSObject {
        @objc func openPanel(_ sender: Any?) {}
        @objc func openSettings(_ sender: Any?) {}
    }
    // Refs: US-39, AC-39.07. Whatever the entry is, the panel and Settings are reachable through the application
    // menu, Settings on the standard Cmd-comma.
    @Test func theApplicationMenuOpensThePanelAndSettings() throws {
        let target = MenuTarget()
        let menu = ApplicationMenu.make(target: target, open: #selector(MenuTarget.openPanel(_:)),
                                        settings: #selector(MenuTarget.openSettings(_:)))
        let application = try #require(menu.item(withTitle: "Lunlet")?.submenu)
        let open = try #require(application.item(withTitle: "Open Lunlet"))
        #expect(open.action == #selector(MenuTarget.openPanel(_:)) && open.target === target)
        let settings = try #require(application.item(withTitle: "Settings…"))
        #expect(settings.action == #selector(MenuTarget.openSettings(_:)) && settings.target === target)
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)
        #expect(application.item(withTitle: "Quit")?.keyEquivalent == "q")
        // Without a target the menu keeps only what needs none.
        #expect(ApplicationMenu.make().item(withTitle: "Lunlet")?.submenu?.item(withTitle: "Settings…") == nil)
    }
}
