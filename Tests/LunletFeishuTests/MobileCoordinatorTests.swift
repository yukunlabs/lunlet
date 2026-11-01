// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.01, AC-05.02, AC-05.03; US-06, AC-06.01, AC-06.05.
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.01, AC-08.03, AC-08.04.
// Refs: US-10, AC-10.01, AC-10.03, AC-10.04; US-11, AC-11.01, AC-11.02, AC-11.03.
// Refs: US-12, AC-12.01, AC-12.02, AC-12.03, AC-12.04.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

private actor SyntheticCardSender: FeishuCardSending {
    private(set) var cards: [FeishuCardDelivery] = []
    private var held = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var closed = false
    func hold() { held = true }
    func release() { held = false; pending?.resume(); pending = nil }
    func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) async throws -> FeishuMessageReceipt {
        cards.append(delivery)
        if held { await withCheckedContinuation { pending = $0 } }
        return .init(messageID: "om_synthetic", chatID: "oc_synthetic", applicationID: "cli_synthetic",
                     ownerID: "ou_owner", tenantID: "tenant_synthetic")
    }
    func close() { closed = true; release() }
}

private final class CoordinatorActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeishuSocketAction] = []
    func append(_ value: FeishuSocketAction) { lock.withLock { values.append(value) } }
    func snapshot() -> [FeishuSocketAction] { lock.withLock { values } }
}

struct MobileCoordinatorTests {
    private let connection = UUID()
    private func snapshot(id: UUID = UUID(), phase: SessionPhase = .idle(completedTurnID: "turn")) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: id, connectionID: UUID(), liveness: .alive, phase: phase),
                        project: "Lunlet", title: "Session")
    }
    private func coordinator(_ sender: SyntheticCardSender, actions: CoordinatorActions = CoordinatorActions()) -> MobileCoordinator {
        MobileCoordinator(sender: sender, router: .init(elapsed: { 0 }, wallTime: { CardCallbackFixture.date }),
                          onAction: { actions.append($0) })
    }
    private func ready(_ value: MobileCoordinator) async {
        await value.configure(owner: CardCallbackFixture.owner, connectionID: connection, callbacksVerified: true, adapterAvailable: true)
    }
    private func waitForCards(_ sender: SyntheticCardSender, count: Int) async throws {
        for _ in 0..<2_000 {
            if await sender.cards.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected the coordinator to publish the eligible snapshot")
        throw URLError(.timedOut)
    }
    private func control(_ delivery: FeishuCardDelivery) throws -> UUID {
        let json = try JSONSerialization.jsonObject(with: Data(delivery.content.utf8)) as! [String: Any]
        let body = json["body"] as! [String: Any]
        let form = try #require((body["elements"] as! [[String: Any]]).first { $0["tag"] as? String == "form" })
        let button = try #require((form["elements"] as! [[String: Any]]).first { $0["name"] as? String == "submit" })
        let value = (button["behaviors"] as! [[String: Any]])[0]["value"] as! [String: String]
        return try #require(UUID(uuidString: value["lunlet_control"]!))
    }

    private func accepted(_ router: CardActionRouter, id: UUID, event: String) async throws -> AuthorizedContinuation {
        let payload = try CardCallbackFixture.data(control: id, event: event)
        for _ in 0..<2_000 {
            if case .received(let action) = await router.handle(payload, connectionID: connection) { return action }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The delivered form was never bound for the verified owner")
        throw URLError(.timedOut)
    }

    @Test func setupAndAdapterProofAreRequiredBeforeAwayMode() async {
        let sender = SyntheticCardSender(), coordinator = coordinator(sender)
        #expect(await coordinator.setAwayMode(true) == false)
        await coordinator.configure(owner: CardCallbackFixture.owner, connectionID: connection,
                                    callbacksVerified: false, adapterAvailable: true)
        #expect(await coordinator.setAwayMode(true) == false)
        await coordinator.configure(owner: CardCallbackFixture.owner, connectionID: connection,
                                    callbacksVerified: true, adapterAvailable: false)
        #expect(await coordinator.setAwayMode(true) == false)
        #expect(await sender.cards.isEmpty)
        await coordinator.close()
    }

    @Test func enablingAwayIncludesExistingWaitingSessionsAndQuietlyTracksRunningOnes() async throws {
        let sender = SyntheticCardSender(), coordinator = coordinator(sender)
        await ready(coordinator)
        let first = snapshot(), second = snapshot(phase: .approval), running = snapshot(phase: .running)
        await coordinator.observe(first); await coordinator.observe(second); await coordinator.observe(running)
        #expect(await sender.cards.isEmpty)
        #expect(await coordinator.setAwayMode(true))
        try await waitForCards(sender, count: 2)
        let later = snapshot()
        await coordinator.observe(later)
        try await waitForCards(sender, count: 3)
        await coordinator.observe(later)
        await coordinator.close()
        #expect(await sender.cards.count == 3)
        #expect(await sender.closed)
    }

    @Test func aLateSendCannotBindOrDispatchAfterAwayWasDisabled() async throws {
        let sender = SyntheticCardSender(), actions = CoordinatorActions(), coordinator = coordinator(sender, actions: actions)
        await ready(coordinator)
        await sender.hold()
        #expect(await coordinator.setAwayMode(true))
        await coordinator.observe(snapshot())
        try await waitForCards(sender, count: 1)
        let id = try control(await sender.cards[0])
        #expect(await coordinator.setAwayMode(false))
        await sender.release()
        let callback = try CardCallbackFixture.data(control: id)
        let router = await coordinator.router
        #expect(await router.handle(callback, connectionID: connection).isUnavailableForCoordinatorTest)
        await coordinator.close()
        #expect(actions.snapshot().isEmpty)
    }

    @Test func replacementConnectionsRequireFreshObservationsAndControls() async throws {
        let sender = SyntheticCardSender(), coordinator = coordinator(sender)
        await ready(coordinator)
        #expect(await coordinator.setAwayMode(true))
        let value = snapshot()
        await coordinator.observe(value)
        try await waitForCards(sender, count: 1)
        let old = try control(await sender.cards[0])
        await coordinator.configure(owner: CardCallbackFixture.owner, connectionID: UUID(), callbacksVerified: true, adapterAvailable: true)
        await coordinator.observe(value)
        try await waitForCards(sender, count: 2)
        let fresh = try control(await sender.cards[1])
        #expect(old != fresh)
        let router = await coordinator.router
        #expect(await router.handle(try CardCallbackFixture.data(control: old), connectionID: connection).isUnavailableForCoordinatorTest)
        await coordinator.close()
    }

    @Test func acceptedActionsAreClaimedOnceAndQueuedActionsCannotSurviveInputDisable() async throws {
        let sender = SyntheticCardSender(), actions = CoordinatorActions(), coordinator = coordinator(sender, actions: actions)
        await ready(coordinator)
        #expect(await coordinator.setAwayMode(true))
        let first = snapshot()
        await coordinator.observe(first)
        try await waitForCards(sender, count: 1)
        let router = await coordinator.router
        let received = try await accepted(router, id: control(await sender.cards[0]), event: "event_first")
        let socketAction = FeishuSocketAction(connectionID: connection, continuation: received)
        await coordinator.receive(socketAction)
        await coordinator.receive(socketAction)
        #expect(actions.snapshot().count == 1)
        #expect(actions.snapshot().first?.continuation.session == first.observation)
        let second = snapshot()
        await coordinator.observe(second)
        try await waitForCards(sender, count: 2)
        let another = try await accepted(router, id: control(await sender.cards[1]), event: "event_second")
        await coordinator.receive(.init(connectionID: connection, continuation: another))
        #expect(actions.snapshot().count == 2)
        #expect(actions.snapshot().last?.continuation.session == second.observation)
        await coordinator.observe(snapshot())
        try await waitForCards(sender, count: 3)
        let queued = try await accepted(router, id: control(await sender.cards[2]), event: "event_third")
        await coordinator.setRemoteInput(false)
        await coordinator.setRemoteInput(true)
        await coordinator.receive(.init(connectionID: connection, continuation: queued))
        #expect(actions.snapshot().count == 2)
        await coordinator.close()
    }

    @Test func endedBindingsCannotBeRepublishedOrRevivedByADelayedAliveSnapshot() async throws {
        let sender = SyntheticCardSender(), coordinator = coordinator(sender)
        await ready(coordinator)
        #expect(await coordinator.setAwayMode(true))
        let first = snapshot()
        await coordinator.observe(first)
        try await waitForCards(sender, count: 1)
        await coordinator.observe(.init(observation: .init(sessionID: first.observation.sessionID,
            connectionID: first.observation.connectionID, liveness: .ended, phase: .ended), project: "Lunlet", title: "Session"))
        await coordinator.observe(first)
        let router = await coordinator.router
        #expect(await router.prepare(sessionID: first.observation.sessionID, form: .followup(field: "followup")) == nil)
        // Close drains publication tasks, so no fixed delay can hide a late send.
        await coordinator.close()
        #expect(await sender.cards.count == 1)
    }

    @Test func queuedActionsCannotReviveAfterObservationLossOrAnInterveningApproval() async throws {
        for unavailable in [SessionPhase.unknown, .approval] {
            let sender = SyntheticCardSender(), actions = CoordinatorActions(), coordinator = coordinator(sender, actions: actions)
            await ready(coordinator)
            #expect(await coordinator.setAwayMode(true))
            let first = snapshot()
            await coordinator.observe(first)
            try await waitForCards(sender, count: 1)
            let router = await coordinator.router
            let received = try await accepted(router, id: control(await sender.cards[0]), event: "event_queued")
            await coordinator.observe(.init(observation: .init(sessionID: first.observation.sessionID,
                connectionID: first.observation.connectionID, liveness: unavailable == .unknown ? .unverified : .alive,
                phase: unavailable), project: first.project, title: first.title))
            await coordinator.observe(first)
            await coordinator.receive(.init(connectionID: connection, continuation: received))
            #expect(actions.snapshot().isEmpty)
            await coordinator.close()
        }
    }

    @Test func delayedStateSynchronizationCannotRevokeNewerAccess() async throws {
        let router = CardActionRouter(elapsed: { 0 }, wallTime: { CardCallbackFixture.date })
        let value = snapshot()
        let access = MobileAccess(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true)
        #expect(await router.synchronize(revision: 2, access: access, connectionID: connection,
                                         observations: [value.observation]))
        #expect(await router.synchronize(revision: 1,
            access: .init(owner: nil, connected: false, awayMode: false, inputEnabled: false),
            connectionID: nil, observations: []) == false)
        #expect(await router.prepare(sessionID: value.observation.sessionID, form: .followup(field: "followup")) != nil)
    }
}

private extension CardActionResult {
    var isUnavailableForCoordinatorTest: Bool { if case .unavailable = self { return true }; return false }
}
