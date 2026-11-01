// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-36, AC-36.01, AC-36.02; US-05, AC-05.09; US-08, AC-08.03.
import Foundation
import Testing
import LunletCore
import LunletMessaging
@testable import LunletDesktop

/// Records the reply affordance of each notice; no network, credentials or Codex input.
private actor NoticeClient: ChannelReplyClient {
    private(set) var sent: [NoticeReplyState?] = []
    func prepare() -> BotIdentity { .init(channel: .telegram, id: "9001", name: "SyntheticBot") }
    func pair(_ challenge: PairingChallenge) throws -> BotBinding { throw BotChannelFailure.unavailable }
    func checkAuthorization(_ binding: BotBinding) {}
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) -> BotMessageReceipt {
        sent.append(reply); return .init(messageID: "m\(sent.count)", chatID: binding.chatID)
    }
    func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) {}
    func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        do { try await Task.sleep(for: .seconds(3_600)) } catch { throw BotChannelFailure.canceled }
    }
    func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) -> String? { nil }
    func sendText(_ text: String, binding: BotBinding) {}
    func close() {}
}

struct OwnerChannelCompletionSenderTests {
    // Observations and the lock state reach the reply service in the order they happened on the Mac, so a notice
    // for the newest completed turn takes a reply and a notice for an older state never does, however quickly the
    // session changed.
    @Test func observationsReachTheReplyServiceInOrder() async throws {
        let binding = BotBinding(channel: .telegram, botID: "9001", botName: "SyntheticBot", ownerID: "42", chatID: "42")
        let enrollment = try BotEnrollment(credentials: .init(channel: .telegram, botToken: "9001:synthetic-token"), binding: binding)
        let client = NoticeClient()
        let sender = OwnerChannelCompletionSender(enrollment: enrollment, client: client, dispatch: { _, _ in .delivered })
        let session = UUID(), connection = UUID()
        func snapshot(_ phase: SessionPhase) -> SessionSnapshot {
            SessionSnapshot(observation: .init(sessionID: session, connectionID: connection, liveness: .alive, phase: phase),
                            project: "Synthetic", title: "Task")
        }
        sender.lockChanged(true)
        for turn in 0..<200 {
            sender.observe(snapshot(.running))
            sender.observe(snapshot(.idle(completedTurnID: "turn-\(turn)")))
        }
        try await sender.send(snapshot(.idle(completedTurnID: "turn-199")))
        try await sender.send(snapshot(.idle(completedTurnID: "turn-198")))
        sender.lockChanged(false)
        sender.observe(snapshot(.idle(completedTurnID: "turn-200")))
        try await sender.send(snapshot(.idle(completedTurnID: "turn-200")))
        #expect(await client.sent == [.open, nil, nil])
        await sender.close()
    }
}
