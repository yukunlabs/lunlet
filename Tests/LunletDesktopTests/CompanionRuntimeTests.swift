// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.01, AC-20.02; US-12, AC-12.04; US-26, AC-26.01.
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
