// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04; US-24, AC-24.03; US-12, AC-12.05; US-39, AC-39.07.
import AppKit

/// The main menu of an accessory app is never shown, but it still routes the standard key equivalents: without an
/// Edit menu, Cmd-V, Cmd-C, Cmd-X, Cmd-A and Cmd-Z do nothing in the channel setup's token fields. With a target it
/// also carries Open Lunlet and Settings on Cmd-comma, so both stay reachable whatever the entry is (AC-39.07).
@MainActor public enum ApplicationMenu {
    public static func make(target: AnyObject? = nil, open: Selector? = nil, settings: Selector? = nil) -> NSMenu {
        let menu = NSMenu()
        let application = NSMenu()
        menu.setSubmenu(application, for: menu.addItem(withTitle: "Lunlet", action: nil, keyEquivalent: ""))
        if let target {
            if let open { application.addItem(withTitle: "Open Lunlet", action: open, keyEquivalent: "").target = target }
            if let settings { application.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",").target = target }
            application.addItem(.separator())
        }
        let quit = application.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        // Edit actions go to the first responder, so the focused field editor handles them.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.setSubmenu(edit, for: menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: ""))
        return menu
    }
}
