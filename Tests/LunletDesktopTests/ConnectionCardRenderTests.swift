// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.02, AC-22.03; US-20, AC-20.04; US-01, AC-01.01, AC-01.02.
// Opt-in offscreen renders of the connection card in each channel's setup states, for owner review. Synthetic stores
// and clients only; no Keychain, network or real credentials.
import AppKit
import Foundation
import SwiftUI
import Testing
import LunletCore
import LunletMessaging
@testable import LunletFeishu
@testable import LunletDesktop

private actor CardEnrollmentStore: EnrollmentStoring {
    enum Mode { case empty, saved, failing }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func save(_ enrollment: FeishuEnrollment) {}
    func load() throws -> FeishuEnrollment? {
        switch mode {
        case .empty: nil
        case .saved: FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic", secret: "synthetic", isLark: false)
        case .failing: throw URLError(.cannotOpenFile)
        }
    }
    func authorizeSavedEnrollment() throws -> FeishuEnrollment? { try load() }
    func remove() {}
}
private actor CardCredentialStore: ChannelCredentialStoring {
    let saved: Data?
    init(_ saved: Data? = nil) { self.saved = saved }
    func load() -> Data? { saved }
    func authorize() -> Data? { saved }
    func save(_ data: Data) {}
    func remove() {}
}
private actor CardBotClient: ChannelBotClient {
    enum Mode { case failing, holding }
    let channel: BotChannel
    let mode: Mode
    init(_ channel: BotChannel, _ mode: Mode) { self.channel = channel; self.mode = mode }
    func prepare() throws -> BotIdentity {
        if mode == .failing { throw BotChannelFailure.unavailable }
        return .init(channel: channel, id: channel == .telegram ? "9001" : "B123", name: channel == .telegram ? "LunletSyntheticBot" : "Lunlet",
                     workspaceID: channel == .slack ? "T123" : nil, applicationID: channel == .slack ? "A123" : nil)
    }
    func pair(_ challenge: PairingChallenge) async throws -> BotBinding {
        try await Task.sleep(for: .seconds(60)); throw BotChannelFailure.canceled
    }
    func checkAuthorization(_ binding: BotBinding) {}
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding) -> BotMessageReceipt { .init(messageID: "1", chatID: binding.chatID) }
    func close() {}
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"] != nil))
@MainActor struct ConnectionCardRenderTests {
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }
    private static func binding(_ channel: BotChannel) -> BotBinding {
        .init(channel: channel, botID: channel == .telegram ? "9001" : "B123", botName: channel == .telegram ? "LunletSyntheticBot" : "Lunlet",
              ownerID: channel == .telegram ? "42" : "U123", chatID: channel == .telegram ? "42" : "D123",
              workspaceID: channel == .slack ? "T123" : nil, applicationID: channel == .slack ? "A123" : nil)
    }

    @Test func rendersEveryChannelsSetupStates() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, channel, state) in [("disconnected", BotChannel.slack, "empty"), ("failed", .slack, "failing"), ("pairing", .slack, "pairing"),
                                       ("enrolled", .slack, "saved"), ("disconnected", .telegram, "empty"), ("pairing", .telegram, "pairing"),
                                       ("enrolled", .telegram, "saved")] {
            let saved = state == "saved" ? try JSONEncoder().encode(try BotEnrollment(
                credentials: .init(channel: channel, botToken: channel == .telegram ? "9001:synthetic" : "xoxb-synthetic",
                                   appToken: channel == .slack ? "xapp-synthetic" : nil), binding: Self.binding(channel))) : nil
            let client = CardBotClient(channel, state == "failing" ? .failing : .holding)
            let model = BotChannelSetupModel(storeFactory: { _ in CardCredentialStore(saved) }, clientFactory: { _ in client })
            model.select(channel)
            await wait { model.state != .loading }
            if state == "failing" || state == "pairing" {
                model.connect(.init(channel: channel, botToken: channel == .telegram ? "9001:synthetic" : "xoxb-synthetic",
                                    appToken: channel == .slack ? "xapp-synthetic" : nil))
                await wait { model.state == (state == "failing" ? .failed : .pairing) }
            }
            try await render(channel: channel == .slack ? .slack : .telegram, feishu: CardEnrollmentStore(.empty), bot: model,
                             name: "\(channel.rawValue)-\(name)", to: directory)
            await model.shutdown()
        }
        for (name, mode) in [("disconnected", CardEnrollmentStore.Mode.empty), ("enrolled", .saved), ("failed", .failing)] {
            let bot = BotChannelSetupModel(storeFactory: { _ in CardCredentialStore() })
            try await render(channel: .feishu, feishu: CardEnrollmentStore(mode), bot: bot, name: "feishu-\(name)", to: directory)
            await bot.shutdown()
        }
    }

    private func render(channel: CommunicationChannel, feishu store: CardEnrollmentStore, bot: BotChannelSetupModel,
                        name: String, to directory: URL) async throws {
        let suite = "com.lunlet.test.card.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.channel = channel }
        let setup = FeishuSetupModel(store: store)
        await setup.load()
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RenderPower())
        for dark in [false, true] {
            let root = ConnectionCard(preferences: preferences, setup: setup, botSetup: bot, notifications: notifications,
                                      bodyLimit: 320, close: {})
                .padding(24)
                .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = hosting.fittingSize
            hosting.frame = .init(origin: .zero, size: .init(width: max(size.width, ConnectionCard.width + 48), height: max(size.height, 80)))
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("card-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
