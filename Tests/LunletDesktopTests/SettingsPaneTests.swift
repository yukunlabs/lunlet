// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-31, AC-31.01, AC-31.02, AC-31.04; US-04, AC-04.04; US-19, AC-19.01; US-21, AC-21.04, AC-21.05.
// Refs: US-40, AC-40.01; US-33, AC-33.08; US-38, AC-38.06; US-29, AC-29.05; US-24, AC-24.01, AC-24.02.
// Refs: US-42, AC-42.03.
import AppKit
import SwiftUI
import Testing
import LunletClaude
import LunletCore
@testable import LunletDesktop

// AC-31.01, AC-31.04: five categories in the confirmed order, Appearance first unless a page asked for another.
@Test func settingsTabsKeepTheConfirmedOrderAndOpenOnAppearance() {
    #expect(SettingsModel.tabs == [.appearance, .usage, .agents, .messaging, .about])
    #expect(SettingsModel.opening(nil) == .appearance && SettingsModel.opening(.agents) == .agents)
    #expect(SettingsModel.tabLabel(.usage) == "Usage settings")
    // Arrow keys move through the tabs and stop at the ends (AC-24.01).
    #expect(SettingsModel.neighbor(of: .appearance, offset: 1) == .usage)
    #expect(SettingsModel.neighbor(of: .appearance, offset: -1) == nil && SettingsModel.neighbor(of: .about, offset: 1) == nil)
}

// AC-31.02: an entry's own options are shown only while that entry is selected, as before the redesign.
@Test func anEntryShowsItsOwnOptionsOnlyWhileItIsSelected() {
    var value = LunletPreferences()
    // AC-42.03: only the notch entry would stay over a full-screen window, so only it offers the choice.
    #expect(SettingsModel.entryOptions(value, packsListed: true) == [.fullScreen])
    value.presentation = .menuBar
    #expect(SettingsModel.entryOptions(value, packsListed: true) == [.showAllowance])
    value.menuBarAllowance = .percentAndReset
    #expect(SettingsModel.entryOptions(value, packsListed: true) == [.showAllowance, .onlyBelow])
    value.presentation = .pet
    #expect(SettingsModel.entryOptions(value, packsListed: true) == [.pet, .coat, .packs])
    // A chosen pack has its own colors, so the coat leaves; without a pack library only the coat can be chosen.
    value.petPack = "lunlet/mochi"
    #expect(SettingsModel.entryOptions(value, packsListed: true) == [.pet, .packs])
    #expect(SettingsModel.entryOptions(value, packsListed: false) == [.coat])
    // The pictured options are the three entries, in their stored order and with their own names.
    #expect(SettingsModel.entries.map(\.title) == ["Notch widget", "Menu bar", "Desktop pet"])
}

// AC-04.04: Settings names where each figure comes from, with the credential handling in help, only for agents shown.
@Test func theSourcesGroupNamesWhatEachSelectedAgentReads() {
    let both = SettingsModel.sources(providers: [.codex, .claude])
    #expect(both.map(\.label) == ["Codex limits", "Claude Code limits", "Tokens and cost"])
    #expect(both.map(\.value) == ["Your local Codex sign-in · OpenAI account", "Claude Code's status line",
                                  "Recorded on this Mac · API list prices"])
    #expect(both[0].help?.contains("Sign-in credentials are never sent through messaging channels") == true)
    #expect(both[1].help?.contains("reads no credentials") == true)
    #expect(SettingsModel.sources(providers: [.codex]).map(\.label) == ["Codex limits", "Tokens and cost"])
    #expect(SettingsModel.sources(providers: [.claude]).map(\.label) == ["Claude Code limits", "Tokens and cost"])
}

// AC-19.01: agents are chosen one by one and one always stays on.
@Test func oneAgentAlwaysStaysOn() {
    #expect(!SettingsModel.canTurnOff(.codex, selected: [.codex]))
    #expect(SettingsModel.canTurnOff(.codex, selected: [.codex, .claude]))
    #expect(SettingsModel.toggled(.claude, on: false, in: [.codex, .claude]) == [.codex])
    #expect(SettingsModel.toggled(.claude, on: true, in: [.codex]) == [.codex, .claude])
    #expect(SettingsModel.toggled(.claude, on: true, in: [.codex, .claude]) == [.codex, .claude])
}

// AC-33.08, AC-38.06: the Agents page says each Claude Code connection's state in words and offers only the action
// that state needs; color never carries it alone (AC-24.02).
@Test func claudeConnectionRowsSayTheStateAndOfferOnlyTheActionItNeeds() {
    #expect(ClaudePlanLimitsSettings.status(connection: .connected, issue: nil)
            == SettingsStatus(text: "Status line connected", tone: .success, action: nil))
    #expect(ClaudePlanLimitsSettings.status(connection: .checking, issue: nil) == SettingsStatus(text: "Checking…", tone: .neutral, action: nil))
    #expect(ClaudePlanLimitsSettings.status(connection: .notConnected, issue: nil)
            == SettingsStatus(text: "Not connected", tone: .neutral, action: nil))
    #expect(ClaudePlanLimitsSettings.status(connection: .changedOutsideLunlet, issue: nil)
            == SettingsStatus(text: "Claude Code's status line was changed after Lunlet connected; Lunlet leaves it alone.",
                              tone: .attention, action: .forget))
    #expect(ClaudePlanLimitsSettings.status(connection: .unavailable(.claudeDirectoryMissing), issue: nil)
            == SettingsStatus(text: ClaudePlanLimitsSettings.message(.claudeDirectoryMissing), tone: .attention, action: nil))
    // A change that failed keeps its note and its Try again whatever the connection reads.
    #expect(ClaudePlanLimitsSettings.status(connection: .connected, issue: .writeFailed)
            == SettingsStatus(text: ClaudePlanLimitsSettings.message(.writeFailed), tone: .attention, action: .retry))
    // A line changed outside Lunlet keeps Forget beside such a note, as before.
    #expect(ClaudePlanLimitsSettings.status(connection: .changedOutsideLunlet, issue: .writeFailed)
            == SettingsStatus(text: ClaudePlanLimitsSettings.message(.writeFailed), tone: .attention, action: .forget))

    #expect(ClaudeHookSettings.status(connection: .connected, issue: nil) == SettingsStatus(text: "Stop hook added", tone: .success, action: nil))
    #expect(ClaudeHookSettings.status(connection: .notConnected, issue: nil) == SettingsStatus(text: "Not added", tone: .neutral, action: nil))
    #expect(ClaudeHookSettings.status(connection: .unavailable(.claudeDirectoryMissing), issue: nil)
            == SettingsStatus(text: ClaudeHookSettings.message(.claudeDirectoryMissing), tone: .attention, action: nil))
    #expect(ClaudeHookSettings.status(connection: .notConnected, issue: .settingsChanged)
            == SettingsStatus(text: ClaudeHookSettings.message(.settingsChanged), tone: .attention, action: .retry))
    // Only a state that needs the owner makes the row a note; a healthy one is a single status word.
    #expect(!ClaudePlanLimitsSettings.status(connection: .connected, issue: nil).needsAttention)
    #expect(ClaudeHookSettings.status(connection: .notConnected, issue: .settingsChanged).needsAttention)
}

@MainActor private func settingsModels() throws -> (PreferencesStore, SkinCatalog, () -> Void) {
    let (defaults, suite) = try ScratchSettings.make("settings")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-settings-\(UUID())")
    return (PreferencesStore(defaults: defaults), SkinCatalog(directory: directory), {
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
    })
}

// AC-29.05, AC-35.03: About is one page beside the update controls; it never needs to scroll under the tabs.
@MainActor @Test func aboutStaysOnOnePageUnderTheTabs() throws {
    _ = NSApplication.shared
    let (preferences, skins, cleanUp) = try settingsModels(); defer { cleanUp() }
    let updater = AppUpdater(driver: SyntheticUpdateDriver())
    updater.updateFound(version: "0.2.0", shownBySparkle: false)
    for shown in [nil, updater] as [AppUpdater?] {
        let hosting = NSHostingView(rootView: SettingsAbout(preferences: preferences, skins: skins, updater: shown)
            .frame(width: PanelPlacement.panelWidth).fixedSize(horizontal: false, vertical: true))
        hosting.frame = .init(x: 0, y: 0, width: PanelPlacement.panelWidth, height: 600)
        hosting.layoutSubtreeIfNeeded()
        let available = PanelStyle.Layout.settingsPageHeight - SettingsStyle.tabBarHeight
        #expect(hosting.fittingSize.height <= available, "About needs \(hosting.fittingSize.height) of \(available)")
    }
}

/// Opt-in offscreen renders of every Settings page and entry variant, light and dark, for review. Set
/// `LUNLET_RENDER_DIR` to a directory outside the repository; glass is approximated by a flat fill.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"] != nil))
@MainActor struct SettingsPaneRenderTests {
    @Test func renderEverySettingsPage() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let updater = AppUpdater(driver: SyntheticUpdateDriver())
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        let pages: [(String, PreferenceCategory, (inout LunletPreferences) -> Void)] = [
            ("appearance-notch", .appearance, { _ in }),
            ("appearance-menubar", .appearance, { $0.presentation = .menuBar; $0.menuBarAllowance = .percent }),
            ("appearance-pet", .appearance, { $0.presentation = .pet }),
            ("usage", .usage, { $0.allowanceNotifications = true }),
            ("usage-off", .usage, { _ in }),
            ("agents", .agents, { _ in }),
            ("messaging", .messaging, { _ in }),
            ("about", .about, { _ in }),
        ]
        for (name, category, change) in pages {
            for dark in [false, true] {
                let (preferences, skins, cleanUp) = try settingsModels(); defer { cleanUp() }
                preferences.update { $0.providers = [.codex, .claude]; change(&$0) }
                let notifications = LockedCompletionNotifications(isLocked: { false }, power: RenderPower())
                let pane = PreferencesPane(preferences: preferences, skins: skins, setup: FeishuSetupModel(store: RenderEnrollmentStore()),
                                           botSetup: BotChannelSetupModel(storeFactory: { _ in RenderCredentialStore() }),
                                           notifications: notifications, openConnection: {}, initialCategory: category)
                let size = CGSize(width: PanelPlacement.panelWidth, height: PanelStyle.Layout.settingsPageHeight)
                // Empty synthetic pack folders: the owner's real pets are never listed.
                let packs = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-settings-packs-\(UUID())")
                defer { try? FileManager.default.removeItem(at: packs) }
                let library = PetPackLibrary(lunletDirectory: packs.appendingPathComponent("lunlet"),
                                             codexDirectory: packs.appendingPathComponent("codex"))
                let root = pane.environment(\.appUpdater, updater).environment(\.petPacks, library)
                    .tint(skins.controlTint(for: preferences.value).color)
                    .font(PanelStyle.Text.secondary)
                    .frame(width: size.width, height: size.height)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let hosting = NSHostingView(rootView: root)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = .init(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                hosting.layoutSubtreeIfNeeded()
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("settingspane-\(name)-\(dark ? "dark" : "light").png"))
                }
                await notifications.shutdown()
            }
        }
    }
}
