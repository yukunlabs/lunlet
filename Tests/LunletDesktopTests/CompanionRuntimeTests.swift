// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.01, AC-20.02; US-12, AC-12.04; US-26, AC-26.01; US-39, AC-39.05, AC-39.07; US-31, AC-31.01.
// Refs: US-19, AC-19.01; US-25, AC-25.01; US-40, AC-40.01; US-38, AC-38.01, AC-38.07.
import AppKit
import Foundation
import Testing
import LunletSecureStorage
@testable import LunletDesktop
@testable import LunletFeishu
import LunletMessaging

private actor RuntimeCredentialFixture: ChannelCredentialStoring {
    func load() -> Data? { nil }
    func authorize() -> Data? { nil }
    func save(_ data: Data) {}
    func remove() {}
}

private final class RuntimePower: IdleSleepControlling {
    func setEnabled(_ enabled: Bool) {}
}

@MainActor struct CompanionRuntimeTests {
    @Test func changingChannelsImmediatelyDisablesThePreviousSenderAndCanRestoreIt() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = PreferencesStore(defaults: defaults)
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RuntimePower())
        let botSetup = BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() })
        let runtime = CompanionRuntime(preferences: preferences, skins: SkinCatalog(directory: directory), notifications: notifications, botSetup: botSetup)
        // No runtime start, Keychain access, account process, socket or message send.
        runtime.setup.enrollmentChanged?(.init(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                               secret: "synthetic-secret", isLark: false))
        #expect(notifications.status == .ready)
        preferences.update { $0.channel = .telegram }
        #expect(notifications.status == .unavailable)
        preferences.update { $0.channel = .feishu }
        #expect(notifications.status == .ready && notifications.authorizationCheck == .notChecked)
        await runtime.shutdown()
        preferences.update { $0.channel = .slack }
        #expect(notifications.status == .unavailable)
    }
    // Refs: US-39, AC-39.05, AC-39.07. The pet's Settings item and the application menu lead to the Settings page,
    // whether or not the panel's content exists yet.
    @Test func thePetAndTheApplicationMenuAskForTheSettingsPage() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let runtime = CompanionRuntime(preferences: PreferencesStore(defaults: defaults), skins: SkinCatalog(directory: directory),
                                       notifications: LockedCompletionNotifications(isLocked: { false }, power: RuntimePower()),
                                       botSetup: BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() }))
        #expect(runtime.navigation.page == .home)
        runtime.pet.settingsAction?()
        #expect(runtime.navigation.page == .settings && runtime.navigation.settingsEntry == nil)
        runtime.navigation.page = .home
        runtime.navigation.openSettings(.agents)
        #expect(runtime.navigation.page == .settings && runtime.navigation.settingsEntry == .agents)
        await runtime.shutdown()
    }
    // Refs: US-19, AC-19.01; US-25, AC-25.01. Each agent's account and history are read only while it is selected.
    @Test func onlySelectedAgentsHaveTheirAccountAndHistoryRead() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.providers = [.claude] }
        // No runtime start: nothing is read, only the selection is applied.
        let runtime = CompanionRuntime(preferences: preferences, skins: SkinCatalog(directory: directory),
                                       notifications: LockedCompletionNotifications(isLocked: { false }, power: RuntimePower()),
                                       botSetup: BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() }))
        #expect(!runtime.usage.isActive && !runtime.history.isActive && runtime.claudeHistory.isActive)
        preferences.update { $0.providers = [.claude, .codex] }
        #expect(runtime.usage.isActive && runtime.history.isActive && runtime.claudeHistory.isActive)
        preferences.update { $0.providers = [.codex] }
        #expect(runtime.usage.isActive && runtime.history.isActive && !runtime.claudeHistory.isActive)
        await runtime.shutdown()
    }
    // Refs: US-25, AC-25.01; US-40, AC-40.01. Creating the runtime lists no pet packs: the folders are read when
    // Settings or a chosen pack first needs them.
    @Test func creatingTheRuntimeListsNoPetPacks() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let runtime = CompanionRuntime(preferences: PreferencesStore(defaults: defaults), skins: SkinCatalog(directory: directory),
                                       notifications: LockedCompletionNotifications(isLocked: { false }, power: RuntimePower()),
                                       botSetup: BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() }))
        #expect(!runtime.petPacks.hasScanned && runtime.petPacks.entries.isEmpty)
        await runtime.shutdown()
    }

    // Refs: US-38, AC-38.01, AC-38.07; US-25, AC-25.01. The hook helper's files are written once, the first time
    // Claude Code is selected while the app runs, and never for a Mac where it is not selected.
    @Test func theHookHelpersFilesArePreparedOnceAndOnlyForASelectedClaudeCode() {
        var prepared = 0
        let preparation = ClaudeHookPreparation { prepared += 1 }
        preparation.selectionChanged(false, running: true)
        preparation.selectionChanged(true, running: false)
        #expect(prepared == 0)
        preparation.selectionChanged(true, running: true)
        preparation.selectionChanged(true, running: true)
        preparation.selectionChanged(false, running: true)
        preparation.selectionChanged(true, running: true)
        #expect(prepared == 1)
    }

    @Test func inactiveEnrollmentCannotResetTheSelectedProvidersDeliveryOrAuthorizationState() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.channel = .telegram }
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RuntimePower())
        let botSetup = BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() })
        let runtime = CompanionRuntime(preferences: preferences, skins: SkinCatalog(directory: directory), notifications: notifications, botSetup: botSetup)
        let enrollment = try BotEnrollment(credentials: .init(channel: .telegram, botToken: "9001:synthetic-token"),
            binding: .init(channel: .telegram, botID: "9001", botName: "SyntheticBot", ownerID: "42", chatID: "42"))
        botSetup.enrollmentChanged?(enrollment)
        #expect(notifications.status == .ready && notifications.authorizationCheck == .notChecked)
        // Clearing the inactive Feishu enrollment must not reconfigure the selected Telegram sender.
        runtime.setup.enrollmentChanged?(nil)
        #expect(notifications.status == .ready && notifications.authorizationCheck == .notChecked)
        await runtime.shutdown()
        #expect(notifications.status == .unavailable)
    }
    @Test func panelCannotBeReopenedOnceShutdownBegins() async throws {
        _ = NSApplication.shared
        let suite = "com.lunlet.test.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-runtime-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RuntimePower())
        let botSetup = BotChannelSetupModel(storeFactory: { _ in RuntimeCredentialFixture() })
        let runtime = CompanionRuntime(preferences: PreferencesStore(defaults: defaults), skins: SkinCatalog(directory: directory),
                                       notifications: notifications, botSetup: botSetup)
        // No runtime start: no observation, account process or Keychain access.
        await runtime.shutdown()
        runtime.showPanel()
        #expect(!runtime.panel.isVisible)
        await runtime.shutdown()
    }

}
