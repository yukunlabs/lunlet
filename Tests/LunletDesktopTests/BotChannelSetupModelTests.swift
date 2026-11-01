// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.01, AC-20.02, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02; US-22, AC-22.01, AC-22.02, AC-22.03.
import Foundation
import Security
import Testing
import LunletSecureStorage
import LunletCore
import LunletFeishu
import LunletMessaging
@testable import LunletDesktop

private actor SetupCredentialFixture: ChannelCredentialStoring {
    private(set) var saved: Data?
    private(set) var loads = 0
    private(set) var authorizations = 0
    var denied: OSStatus?
    func deny(_ status: OSStatus) { denied = status }
    func load() throws -> Data? { loads += 1; if let denied { throw SecureStorageFailure(status: denied) }; return saved }
    func authorize() -> Data? { authorizations += 1; denied = nil; return saved }
    func save(_ data: Data) { saved = data }
    func remove() { saved = nil }
}
private actor SetupBotFixture: ChannelBotClient {
    let channel: BotChannel
    private(set) var closed = false
    private(set) var pairingStarted = false
    var held = false
    init(_ channel: BotChannel, held: Bool = false) { self.channel = channel; self.held = held }
    func prepare() -> BotIdentity { .init(channel: channel, id: channel == .telegram ? "9001" : "B123", name: "SyntheticBot", workspaceID: channel == .slack ? "T123" : nil, applicationID: channel == .slack ? "A123" : nil) }
    func pair(_ challenge: PairingChallenge) async throws -> BotBinding {
        pairingStarted = true
        if held { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        return .init(channel: channel, botID: channel == .telegram ? "9001" : "B123", botName: "SyntheticBot",
            ownerID: channel == .telegram ? "42" : "U123", chatID: channel == .telegram ? "42" : "D123",
            workspaceID: channel == .slack ? "T123" : nil, applicationID: channel == .slack ? "A123" : nil)
    }
    func checkAuthorization(_ binding: BotBinding) {}
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding) -> BotMessageReceipt { .init(messageID: "1", chatID: binding.chatID) }
    func close() { closed = true }
}

@MainActor struct BotChannelSetupModelTests {
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
    @Test func supportsExactlyThreeChannelsAndMigratesOnlyRetiredWhatsAppSelection() throws {
        #expect(CommunicationChannel.allCases.map(\.rawValue) == ["feishu", "slack", "telegram"])
        let data = Data(#"{"schemaVersion":1,"historyDays":7,"channel":"whatsapp"}"#.utf8)
        let value = try JSONDecoder().decode(LunletPreferences.self, from: data)
        #expect(value.channel == .feishu && value.historyDays == 7)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(LunletPreferences.self, from: Data(#"{"schemaVersion":1,"channel":"other"}"#.utf8)) }
    }
    @Test func bindsAndSavesOnlyPairedPrivateRecipientThenDisconnectsWithoutChangingProviderPreferences() async throws {
        let store = SetupCredentialFixture(), client = SetupBotFixture(.telegram)
        let model = BotChannelSetupModel(storeFactory: { _ in store }, clientFactory: { _ in client })
        var enrollment: BotEnrollment?
        model.enrollmentChanged = { enrollment = $0 }
        model.select(.telegram)
        await wait { model.state == .disconnected }
        // AC-22.01, AC-22.03: the card and Settings show these separate stages; nothing is successful before delivery.
        let before = model.readinessStages(delivery: .unavailable, authorization: .unavailable)
        #expect(before.map(\.id) == ["Authorization", "Private chat", "Completion delivery"])
        #expect(before.map(\.value) == ["Not connected", "Not paired", "Unavailable"])
        #expect(before.allSatisfy { $0.tone != .success } && ChannelHealth(stages: before) == .notConnected)
        model.connect(.init(channel: .telegram, botToken: "9001:synthetic-token"))
        await wait { model.state == .enrolled }
        #expect(enrollment?.binding.chatID == "42" && model.binding?.ownerID == "42")
        let paired = model.readinessStages(delivery: .ready, authorization: .notChecked)
        #expect(paired.map(\.value) == ["Saved on this Mac", "Paired", "Ready when Mac locks"])
        #expect(paired.map(\.tone) == [.running, .success, .running] && ChannelHealth(stages: paired) == .pending)
        #expect(model.readinessStages(delivery: .delivered, authorization: .accepted)[2].tone == .success)
        let saved = try #require(await store.saved)
        let decoded = try BotEnrollment.decode(saved, channel: .telegram)
        #expect(decoded.binding == model.binding)
        model.disconnect()
        await wait { model.state == .disconnected }
        #expect(enrollment == nil && model.binding == nil)
        #expect(await store.saved == nil)
        #expect(await client.closed)
        await model.shutdown()
    }
    @Test func switchingAndQuitCancelPairingAndCannotActivateTheOldChannel() async throws {
        let store = SetupCredentialFixture(), client = SetupBotFixture(.telegram, held: true)
        let model = BotChannelSetupModel(storeFactory: { _ in store }, clientFactory: { _ in client })
        var accepted = 0
        model.enrollmentChanged = { if $0 != nil { accepted += 1 } }
        model.select(.telegram); await wait { model.state == .disconnected }
        model.connect(.init(channel: .telegram, botToken: "9001:synthetic-token"))
        await wait { model.state == .pairing }
        model.select(.slack)
        await wait { model.state == .disconnected }
        #expect(model.channel == .slack && model.challenge == nil && accepted == 0)
        await model.shutdown()
        #expect(await client.closed)
        #expect(accepted == 0)
        #expect(await store.saved == nil)
        model.select(.telegram)
        #expect(model.channel == .slack)
    }
    // Tokens typed into the card belong to the model, so leaving the panel to copy the second token never clears the
    // first; Connect consumes them and a channel change drops them.
    @Test func typedTokensOutliveTheCardUntilConnectOrAChannelChange() async throws {
        let store = SetupCredentialFixture(), client = SetupBotFixture(.slack, held: true)
        let model = BotChannelSetupModel(storeFactory: { _ in store }, clientFactory: { _ in client })
        model.select(.slack); await wait { model.state == .disconnected }
        model.draftBotToken = "xoxb-synthetic"; model.draftAppToken = "xapp-synthetic"
        #expect(model.draftBotToken == "xoxb-synthetic" && model.draftAppToken == "xapp-synthetic")
        model.connect(.init(channel: .slack, botToken: model.draftBotToken, appToken: model.draftAppToken))
        #expect(model.draftBotToken.isEmpty && model.draftAppToken.isEmpty)
        await wait { model.state == .pairing }
        model.cancel(); await wait { model.state == .disconnected }
        model.draftBotToken = "xoxb-again"
        model.select(.telegram); await wait { model.state == .disconnected }
        #expect(model.draftBotToken.isEmpty)
        await model.shutdown()
    }
    @Test(arguments: [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled])
    func rejectedSavedAccessDoesNotPromptOrRetryUntilExplicitAuthorization(status: OSStatus) async throws {
        for channel in [BotChannel.slack, .telegram] {
            let store = SetupCredentialFixture()
            let binding = BotBinding(channel: channel, botID: channel == .telegram ? "9001" : "B123", botName: "SyntheticBot",
                ownerID: channel == .telegram ? "42" : "U123", chatID: channel == .telegram ? "42" : "D123",
                workspaceID: channel == .slack ? "T123" : nil, applicationID: channel == .slack ? "A123" : nil)
            let enrollment = try BotEnrollment(credentials: .init(channel: channel, botToken: "synthetic-token",
                appToken: channel == .slack ? "synthetic-app-token" : nil), binding: binding)
            let saved = try JSONEncoder().encode(enrollment)
            await store.save(saved)
            await store.deny(status)
            let model = BotChannelSetupModel(storeFactory: { _ in store }, clientFactory: { SetupBotFixture($0.channel) })
            model.select(channel)
            await wait { model.state == .accessRequired }
            #expect(await store.loads == 1)
            #expect(await store.authorizations == 0)
            #expect(await store.saved == saved)
            model.select(channel)
            #expect(await store.loads == 1)
            model.authorize()
            await wait { model.state == .enrolled }
            #expect(model.binding == binding)
            #expect(await store.authorizations == 1)
            await model.shutdown()
        }
    }
}

private actor RoutedBotFixture: ChannelReplyClient {
    private(set) var recipients: [BotBinding] = []
    private(set) var checked: [BotBinding] = []
    private(set) var closed = false
    func prepare() -> BotIdentity { .init(channel: .telegram, id: "9001", name: "SyntheticBot") }
    func pair(_ challenge: PairingChallenge) throws -> BotBinding { throw BotChannelFailure.unavailable }
    func checkAuthorization(_ binding: BotBinding) { checked.append(binding) }
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) -> BotMessageReceipt {
        recipients.append(binding); return .init(messageID: "42", chatID: binding.chatID)
    }
    func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) {}
    func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        do { try await Task.sleep(for: .seconds(3_600)) } catch { throw BotChannelFailure.canceled }
    }
    func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) -> String? { nil }
    func sendText(_ text: String, binding: BotBinding) {}
    func close() { closed = true }
}
@MainActor @Test func selectedChannelSenderKeepsTheExactSavedBindingThroughCheckDeliveryAndClose() async throws {
    let binding = BotBinding(channel: .telegram, botID: "9001", botName: "SyntheticBot", ownerID: "42", chatID: "42")
    let enrollment = try BotEnrollment(credentials: .init(channel: .telegram, botToken: "9001:synthetic-token"), binding: binding)
    let client = RoutedBotFixture(), sender = OwnerChannelCompletionSender(enrollment: enrollment, client: client)
    try await sender.checkAuthorization()
    let snapshot = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified,
        phase: .idle(completedTurnID: "synthetic-turn")), project: "Synthetic", title: "Task", turnID: "synthetic-turn", activityConfirmed: true)
    try await sender.send(snapshot)
    #expect(await client.checked == [binding])
    #expect(await client.recipients == [binding])
    await sender.close()
    #expect(await client.closed)
    await #expect(throws: BotChannelFailure.canceled) { try await sender.send(snapshot) }
}

private actor HeldCredentialWrite: ChannelCredentialStoring {
    private(set) var started = false
    private(set) var removals = 0
    private(set) var data: Data?
    private var release: CheckedContinuation<Void, Never>?
    func load() -> Data? { data }
    func authorize() -> Data? { data }
    func save(_ data: Data) async {
        started = true
        await withCheckedContinuation { release = $0 }
        self.data = data
    }
    func finish() { release?.resume(); release = nil }
    func remove() { removals += 1; data = nil }
}
@MainActor @Test func disconnectWaitsForCanceledCredentialWriteBeforeRemovingTheConnection() async {
    let store = HeldCredentialWrite(), client = SetupBotFixture(.telegram)
    let model = BotChannelSetupModel(storeFactory: { _ in store }, clientFactory: { _ in client })
    model.select(.telegram)
    let ready = ContinuousClock.now + .seconds(2)
    while model.state != .disconnected, ContinuousClock.now < ready { await Task.yield() }
    model.connect(.init(channel: .telegram, botToken: "9001:synthetic-token"))
    let started = ContinuousClock.now + .seconds(2)
    while !(await store.started), ContinuousClock.now < started { await Task.yield() }
    #expect(await store.started)
    model.disconnect()
    for _ in 0..<20 { await Task.yield() }
    #expect(await store.removals == 0)
    await store.finish()
    let removed = ContinuousClock.now + .seconds(2)
    while model.state != .disconnected, ContinuousClock.now < removed { await Task.yield() }
    #expect(model.state == .disconnected)
    #expect(await store.data == nil)
    await model.shutdown()
}
