// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-07, AC-07.05; US-08, AC-08.01, AC-08.03, AC-08.04, AC-08.05.
// Refs: US-10, AC-10.01, AC-10.02, AC-10.04; US-11, AC-11.03; US-06, AC-06.02.
import Darwin
import Foundation
import Testing
import LunletCore
@testable import LunletCodex
@testable import LunletDesktop
@testable import LunletFeishu

/// Completion cards and owner-bound receipts stay in memory; no provider is contacted.
private actor SyntheticFeishuClient: FeishuCompletionClient {
    private(set) var cards: [String] = []
    private(set) var receipts: [(content: String, owner: FeishuOwner)] = []
    /// In-place card updates, in the order the provider received them.
    private(set) var updates: [(messageID: String, content: String)] = []
    private var uncertain = false
    private var updatesFail = false
    func failCards() { uncertain = true }
    func failUpdates() { updatesFail = true }
    func updateCard(_ delivery: FeishuCardDelivery, messageID: String, owner: FeishuOwner) async throws {
        guard !updatesFail, owner == CardCallbackFixtureOwner.value else { throw FeishuBotFailure.permissionDenied }
        updates.append((messageID, delivery.content))
    }
    func sendCard(_ delivery: FeishuCardDelivery) async throws -> FeishuMessageReceipt {
        cards.append(delivery.content)
        if uncertain { throw FeishuBotFailure.deliveryUncertain }
        return .init(messageID: "om_card_\(cards.count)", chatID: "oc_synthetic", applicationID: "cli_synthetic",
                     ownerID: "ou_owner", tenantID: "tenant_synthetic")
    }
    func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) async throws -> FeishuMessageReceipt {
        receipts.append((delivery.content, owner))
        return .init(messageID: "om_receipt_\(receipts.count)", chatID: "oc_synthetic", applicationID: owner.applicationID,
                     ownerID: owner.userID, tenantID: owner.tenantID)
    }
    func checkAuthorization() {}
    func close() {}
}

/// The long-connection transport stand-in: callbacks pass through the real router as the socket does.
private final class SyntheticTransport: FeishuCallbackConnecting, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var handlers: (CardActionRouter, @Sendable (FeishuSocketAction) -> Void, @Sendable (FeishuCardRefusal) -> Void)?
    var isOpen: Bool { lock.withLock { handlers != nil } }
    func run(router: CardActionRouter, onState: @escaping @Sendable (FeishuTransportState) async -> Void,
             onAction: @escaping @Sendable (FeishuSocketAction) -> Void,
             onRefusal: @escaping @Sendable (FeishuCardRefusal) -> Void) async throws {
        lock.withLock { handlers = (router, onAction, onRefusal) }
        defer { lock.withLock { handlers = nil } }
        await onState(.socketOpen(id))
        do { try await Task.sleep(for: .seconds(3_600)) } catch {}
        throw CancellationError()
    }
    func deliver(_ data: Data) async -> CardActionResult? {
        guard let (router, onAction, onRefusal) = lock.withLock({ handlers }) else { return nil }
        let result = await router.handle(data, connectionID: id)
        if case .refused(_, let report?) = result { onRefusal(report) }
        if case .received(let action) = result { onAction(FeishuSocketAction(connectionID: id, continuation: action)) }
        return result
    }
}

private final class TransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyntheticTransport] = []
    func make() -> any FeishuCallbackConnecting { lock.withLock { let value = SyntheticTransport(); values.append(value); return value } }
    var open: SyntheticTransport? { lock.withLock { values.last { $0.isOpen } } }
}

/// One terminal-attached Codex CLI whose image is a synthetic path that is never executed.
private final class SyntheticCLI: CodexProcessInspecting, @unchecked Sendable {
    let identity = CodexProcessIdentity(pid: 4_242, seconds: 1_800_000_000, microseconds: 1)
    let file: CodexRolloutFile
    init(file: CodexRolloutFile) { self.file = file }
    func scan() throws -> CodexProcessScan { .init(candidates: [.init(process: identity, files: [file])], complete: true) }
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence { process == identity ? .same : .ended }
    func executable(of process: CodexProcessIdentity) -> URL? {
        process == identity ? URL(fileURLWithPath: "/synthetic/codex/bin/codex") : nil
    }
}

/// Stands in for `codex queue`: records the exact invocation and, like the live CLI, records the
/// queued text as the session's next developer message before a new turn starts.
private final class SyntheticQueue: CodexProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexProcessRequest] = []
    private let file: CodexRolloutFile
    init(file: CodexRolloutFile) { self.file = file }
    var requests: [CodexProcessRequest] { lock.withLock { values } }
    func run(_ request: CodexProcessRequest, timeout: Duration) async -> CodexProcessExit {
        lock.withLock { values.append(request) }
        let text = request.arguments.last ?? ""
        try? Rollout.append(Rollout.line("response_item", ["type": "message", "role": "user",
                                                          "content": [["type": "input_text", "text": text]]])
                            + Rollout.line("event_msg", ["type": "task_started", "turn_id": "turn_c"]), to: file)
        return .exited(0)
    }
}

private enum Rollout {
    static let session = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static func line(_ type: String, _ payload: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        data.append(10)
        return data
    }
    static func event(_ name: String, _ turn: String) -> Data { line("event_msg", ["type": name, "turn_id": turn]) }
    static func fixture() throws -> (URL, CodexRolloutFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-reply-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let url = sessions.appendingPathComponent("rollout.jsonl")
        let header = line("session_meta", ["id": session.uuidString.lowercased(), "cwd": "/synthetic/reply-project", "source": "cli"])
        try (header + event("task_started", "turn_a")).write(to: url)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw URLError(.fileDoesNotExist) }
        return (root, .init(url: url.resolvingSymlinksInPath(), device: status.st_dev, inode: status.st_ino))
    }
    static func append(_ data: Data, to file: CodexRolloutFile) throws {
        let handle = try FileHandle(forWritingTo: file.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class ReplyCues: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}
private final class ReplyPower: IdleSleepControlling {
    func setEnabled(_ enabled: Bool) {}
}

@MainActor struct PhoneReplyFlowTests {
    /// The production completion card, which appends the reply box for an issued capability.
    private let renderer = FeishuCompletionCardRenderer.current

    /// Every component of a card, including those nested in forms, column sets and columns.
    private func components(in card: String) throws -> [[String: Any]] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])
        func flatten(_ items: [[String: Any]]) -> [[String: Any]] {
            items.flatMap { item in
                [item] + flatten((item["elements"] as? [[String: Any]] ?? []) + (item["columns"] as? [[String: Any]] ?? []))
            }
        }
        return flatten(try #require((json["body"] as? [String: Any])?["elements"] as? [[String: Any]]))
    }

    private func component(_ tag: String, in card: String) throws -> [String: Any]? {
        try components(in: card).first { $0["tag"] as? String == tag }
    }

    private func token(in card: String) throws -> UUID? {
        guard let button = try component("button", in: card),
              let value = (button["behaviors"] as? [[String: Any]])?.first?["value"] as? [String: String] else { return nil }
        return value[FeishuReplyCapability.controlKey].flatMap(UUID.init(uuidString:))
    }

    /// A provider callback from the paired owner on the given card, timestamped now.
    private func callback(_ token: UUID, message: String, event: String, text: String) throws -> Data {
        let microseconds = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return try JSONSerialization.data(withJSONObject: ["schema": "2.0", "header": [
            "event_id": event, "create_time": String(microseconds), "event_type": "card.action.trigger",
            "tenant_key": "tenant_synthetic", "app_id": "cli_synthetic",
        ], "event": [
            "operator": ["tenant_key": "tenant_synthetic", "open_id": "ou_owner"], "host": "im_message",
            "action": ["value": [FeishuReplyCapability.controlKey: token.uuidString], "tag": "button",
                       "name": "submit", "form_value": [FeishuReplyCapability.fieldName: text]],
            "context": ["open_message_id": message, "open_chat_id": "oc_synthetic"],
        ]])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < end else { Issue.record("The reply flow did not reach the expected state"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private struct Flow {
        let monitor: CodexSessionMonitor
        let observation: SessionObservationModel
        let list: SessionListModel
        let notifications: LockedCompletionNotifications
        let client: SyntheticFeishuClient
        let transports: TransportLog
        let queue: SyntheticQueue
        let file: CodexRolloutFile
        let root: URL

        func shutdown() async {
            await notifications.shutdown(); await observation.shutdown(); list.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A locked Mac whose second completed turn of one session produces a reply-capable card.
    private func flow() async throws -> (Flow, token: UUID) {
        let (root, file) = try Rollout.fixture()
        let monitor = CodexSessionMonitor(processes: SyntheticCLI(file: file))
        let list = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: ReplyCues())
        let observation = SessionObservationModel(model: list, source: monitor)
        let notifications = LockedCompletionNotifications(isLocked: { true }, power: ReplyPower())
        observation.snapshotReceived = { [weak notifications] in notifications?.receive($0, baseline: $1) }
        let client = SyntheticFeishuClient(), transports = TransportLog(), queue = SyntheticQueue(file: file)
        let adapter = CodexQueueAdapter(runner: queue, queueTimeout: .seconds(2), confirmationTimeout: .seconds(2),
                                        pollInterval: .milliseconds(5), baseEnvironment: ["HOME": "/Users/synthetic"])
        notifications.configure(sender: FeishuCompletionSender(
            client: client, renderer: renderer, dispatch: CodexReplyDispatch.make(observation: observation, adapter: adapter),
            connect: { transports.make() }))
        observation.start()
        try await waitUntil { list.sessions.count == 1 }
        // The first completion while locked is sent before any receipt has verified the owner, so it carries no
        // box; its own receipt then verifies the owner and the same card gains its box in place.
        try Rollout.append(Rollout.event("task_complete", "turn_a"), to: file)
        await monitor.refresh()
        try await waitUntil { await client.cards.count == 1 }
        #expect(try token(in: await client.cards[0]) == nil)
        try await waitUntil { await client.updates.count == 1 }
        let boxed = await client.updates[0], boxedToken = try token(in: boxed.content)
        #expect(boxed.messageID == "om_card_1" && boxedToken != nil)
        try Rollout.append(Rollout.line("response_item", ["type": "message", "role": "user", "id": "typed_b",
                                                          "content": [["type": "input_text", "text": "Next step"]]])
                           + Rollout.event("task_started", "turn_b") + Rollout.event("task_complete", "turn_b"), to: file)
        await monitor.refresh()
        try await waitUntil { await client.cards.count == 2 }
        let issued = try #require(try token(in: await client.cards[1]))
        // The newer card's box replaces the first card's, which closes in place.
        try await waitUntil { await client.updates.count == 2 }
        let closed = await client.updates[1]
        #expect(closed.messageID == "om_card_1" && closed.content.contains("Replies closed"))
        let value = Flow(monitor: monitor, observation: observation, list: list, notifications: notifications, client: client,
                         transports: transports, queue: queue, file: file, root: root)
        return (value, issued)
    }

    @Test func aCardReplyContinuesTheSameCodexSessionOnceAndConfirmsDeliveryFromItsRecord() async throws {
        let (flow, issued) = try await flow()
        let transport = try #require(flow.transports.open)
        let text = "Add the missing regression test"
        guard case .received = await transport.deliver(try callback(issued, message: "om_card_2", event: "event_reply", text: text)) else {
            Issue.record("The paired owner's reply on the bound card must be received"); await flow.shutdown(); return
        }
        try await waitUntil { await flow.client.updates.count == 5 }
        // The observed session's own executable, the same session UUID, and nothing from PATH.
        let request = try #require(flow.queue.requests.first)
        #expect(request.executable.path == "/synthetic/codex/bin/codex")
        #expect(request.arguments == ["queue", "--thread", Rollout.session.uuidString.lowercased(), "--message", text])
        #expect(request.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(request.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == flow.root.resolvingSymlinksInPath().path)
        // The replied card itself greys out at once and then shows each step; no separate receipt card is sent.
        let updates = await flow.client.updates.filter { $0.messageID == "om_card_2" }, receipts = await flow.client.receipts
        #expect(updates.count == 3 && receipts.isEmpty)
        for update in updates {
            let input = try #require(try component("input", in: update.content))
            let button = try #require(try component("button", in: update.content))
            #expect(input["disabled"] as? Bool == true && input["default_value"] as? String == text)
            #expect(button["disabled"] as? Bool == true && update.content.contains("reply-project"))
        }
        #expect(updates[0].content.contains("Received</font>** · sending to Codex…"))
        #expect(updates[1].content.contains("Sent</font>** · waiting for Codex to start"))
        #expect(updates[2].content.contains("Delivered</font>** · Codex is continuing on your Mac"))
        // A repeated tap answers with the receipt and never queues again.
        guard case .duplicate(let status) = await transport.deliver(try callback(issued, message: "om_card_2",
                                                                                 event: "event_tap_again", text: text)) else {
            Issue.record("A used card must answer with its receipt"); await flow.shutdown(); return
        }
        #expect(status.status == .processing)
        try await Task.sleep(for: .milliseconds(30))
        #expect(flow.queue.requests.count == 1)
        let quiet = await (flow.client.receipts.count, flow.client.updates.count)
        #expect(quiet == (0, 5))
        await flow.shutdown()
    }

    @Test func aSessionThatStartedAnotherTurnIsNeverQueuedAndTheOwnerIsTold() async throws {
        let (flow, issued) = try await flow()
        try Rollout.append(Rollout.event("task_started", "turn_typed_on_mac"), to: flow.file)
        await flow.monitor.refresh()
        let transport = try #require(flow.transports.open)
        await flow.client.failUpdates()
        _ = await transport.deliver(try callback(issued, message: "om_card_2", event: "event_late", text: "Continue"))
        // A card that cannot be updated in place still gets a session-named receipt.
        try await waitUntil { await flow.client.receipts.count == 1 }
        #expect(await flow.client.receipts[0].content.contains(
            "Not sent to Session 11111111. The session is already working on another turn."))
        #expect(flow.queue.requests.isEmpty)
        await flow.shutdown()
    }
}

private enum CardCallbackFixtureOwner {
    static let value = FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_owner")
}

/// Records what the notification owner forwards, in order.
private final class ForwardingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}
private actor ForwardingSender: CompletionNotificationSending {
    let log: ForwardingLog
    init(log: ForwardingLog) { self.log = log }
    func checkAuthorization() {}
    func send(_ snapshot: SessionSnapshot) { log.append("send") }
    func close() {}
    nonisolated func observe(_ snapshot: SessionSnapshot) { log.append("observe") }
    nonisolated func lockChanged(_ locked: Bool) { log.append(locked ? "locked" : "unlocked") }
}
@MainActor private final class ReplyLock {
    var value: Bool? = true
}

extension PhoneReplyFlowTests {
    private func completed(_ turn: String) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: Rollout.session, connectionID: Rollout.session, liveness: .alive,
                                           phase: .idle(completedTurnID: turn)),
                        project: "reply-project", title: "Synthetic task")
    }

    /// Verifies AC-05.09 and AC-08.01: the production card ends with exactly the capability's reply box, and its
    /// footer states the reply window instead of saying replies are unavailable.
    @Test func theCompletionCardEndsWithAReplyBoxBoundToItsCapability() async throws {
        let client = SyntheticFeishuClient(), transports = TransportLog()
        let sender = FeishuCompletionSender(client: client, renderer: .current, dispatch: { _, _ in .failed },
                                            connect: { transports.make() })
        sender.lockChanged(true)
        sender.observe(completed("turn_a"))
        try await sender.send(completed("turn_a"))
        // Without a verified owner yet, the first card is sent notification-only; its receipt verifies the owner,
        // the connection opens, and the same card is updated in place with a bound reply box.
        let first = try #require(await client.cards.first)
        #expect(try token(in: first) == nil && !first.contains(SessionNotice.repliesUnavailableFooter))
        let boxed = try #require(await client.updates.first), boxedToken = try token(in: boxed.content)
        #expect(boxed.messageID == "om_card_1" && boxedToken != nil && transports.open != nil)
        sender.observe(completed("turn_b"))
        try await sender.send(completed("turn_b"))
        let card = try #require(await client.cards.last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])
        let elements = try #require((json["body"] as? [String: Any])?["elements"] as? [[String: Any]])
        // The reply box ends the card until a reply adds its status below it; the card can be updated in place.
        let form = try #require(elements.first { $0["tag"] as? String == "form" })
        #expect(form["name"] as? String == FeishuReplyCapability.formName && elements.last?["tag"] as? String == "form")
        #expect((json["config"] as? [String: Any])?["update_multi"] as? Bool == true)
        let controls = try components(in: card).filter { ["input", "button", "select_static"].contains($0["tag"] as? String) }
        #expect(controls.count == 2)
        let input = try #require(try component("input", in: card)), button = try #require(try component("button", in: card))
        #expect(input["name"] as? String == FeishuReplyCapability.fieldName && input["required"] as? Bool == true)
        #expect(input["max_length"] as? Int == FeishuReplyCapability.maximumCharacters && input["disabled"] == nil)
        #expect(button["name"] as? String == FeishuReplyCapability.buttonName && button["form_action_type"] as? String == "submit")
        #expect(button["disabled"] == nil)
        let behaviors = try #require(button["behaviors"] as? [[String: Any]])
        #expect(behaviors.count == 1 && behaviors[0]["type"] as? String == "callback")
        let issued = try #require(try token(in: card))
        #expect(behaviors[0]["value"] as? [String: String] == [FeishuReplyCapability.controlKey: issued.uuidString])
        #expect(card.contains(SessionNotice.replyWindowHint) && !card.contains(SessionNotice.repliesUnavailableFooter))
        await sender.close()
    }

    /// Verifies AC-05.09 and AC-08.04: if the provider refuses to add the box to the first card, its
    /// capability is withdrawn so no control dangles, and the next card still takes replies.
    @Test func aFirstCardWhoseBoxCannotBeAddedKeepsNoControl() async throws {
        let client = SyntheticFeishuClient(), transports = TransportLog()
        await client.failUpdates()
        let sender = FeishuCompletionSender(client: client, renderer: .current, dispatch: { _, _ in .failed },
                                            connect: { transports.make() })
        sender.lockChanged(true)
        sender.observe(completed("turn_a"))
        try await sender.send(completed("turn_a"))
        let firstCard = try #require(await client.cards.first), firstToken = try token(in: firstCard)
        let updates = await client.updates
        // With no control bound, the callback connection is not kept open either.
        #expect(firstToken == nil && updates.isEmpty && transports.open == nil)
        sender.observe(completed("turn_b"))
        try await sender.send(completed("turn_b"))
        let lastCard = try #require(await client.cards.last)
        #expect(try token(in: lastCard) != nil)
        await sender.close()
    }

    /// Verifies AC-05.09: an owner verified by an earlier receipt for this enrollment lets the first card after a
    /// relaunch take replies, and each newly verified owner is remembered once.
    @Test func aRememberedOwnerLetsTheFirstCardAfterARelaunchTakeReplies() async throws {
        let client = SyntheticFeishuClient(), transports = TransportLog(), remembered = ForwardingLog()
        let sender = FeishuCompletionSender(client: client, renderer: .current, dispatch: { _, _ in .failed },
                                            connect: { transports.make() }, owner: CardCallbackFixtureOwner.value,
                                            remember: { remembered.append($0.tenantID) })
        sender.lockChanged(true)
        sender.observe(completed("turn_a"))
        try await sender.send(completed("turn_a"))
        #expect(try token(in: try #require(await client.cards.first)) != nil)
        sender.observe(completed("turn_b"))
        try await sender.send(completed("turn_b"))
        #expect(remembered.events.isEmpty)
        await sender.close()

        let fresh = SyntheticFeishuClient(), log = ForwardingLog()
        let unknown = FeishuCompletionSender(client: fresh, renderer: .current, dispatch: { _, _ in .failed },
                                             connect: { transports.make() }, remember: { log.append($0.tenantID) })
        unknown.lockChanged(true)
        unknown.observe(completed("turn_a"))
        try await unknown.send(completed("turn_a"))
        unknown.observe(completed("turn_b"))
        try await unknown.send(completed("turn_b"))
        #expect(log.events == [CardCallbackFixtureOwner.value.tenantID])
        await unknown.close()
    }

    /// Verifies AC-05.09: a box that can no longer take a reply never looks usable. A newer card for the
    /// session and unlocking the Mac both close open boxes in place, with the reason.
    @Test func openReplyBoxesCloseInPlaceWhenReplacedOrWhenTheMacUnlocks() async throws {
        let client = SyntheticFeishuClient(), transports = TransportLog()
        let sender = FeishuCompletionSender(client: client, renderer: .current, dispatch: { _, _ in .failed },
                                            connect: { transports.make() }, owner: CardCallbackFixtureOwner.value)
        sender.lockChanged(true)
        sender.observe(completed("turn_a"))
        try await sender.send(completed("turn_a"))
        sender.observe(completed("turn_b"))
        try await sender.send(completed("turn_b"))
        try await waitUntil { await client.updates.count == 1 }
        let superseded = await client.updates[0]
        #expect(superseded.messageID == "om_card_1" && superseded.content.contains(ContinuationRefusal.superseded.explanation))
        sender.lockChanged(false)
        try await waitUntil { await client.updates.count == 2 }
        let unlocked = await client.updates[1]
        #expect(unlocked.messageID == "om_card_2" && unlocked.content.contains(ContinuationRefusal.replyWindowClosed.explanation))
        for update in [superseded, unlocked] {
            #expect(try component("input", in: update.content)?["disabled"] as? Bool == true)
            #expect(try component("button", in: update.content)?["disabled"] as? Bool == true)
        }
        await sender.close()
    }

    @Test func anUncertainCardSendWithdrawsItsReplyControlAndClosesTheConnection() async throws {
        let client = SyntheticFeishuClient(), transports = TransportLog()
        let sender = FeishuCompletionSender(client: client, renderer: renderer, dispatch: { _, _ in .failed },
                                            connect: { transports.make() })
        sender.lockChanged(true)
        // The first card verifies the owner but gains no box (the provider refuses the update), so no control is live.
        await client.failUpdates()
        sender.observe(completed("turn_a"))
        try await sender.send(completed("turn_a"))
        await client.failCards()
        sender.observe(completed("turn_b"))
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await sender.send(completed("turn_b")) }
        // The second card was rendered with a reply form, but its control never became usable.
        let second = await client.cards[1]
        #expect(try token(in: second) != nil)
        try await waitUntil { transports.open == nil }
        await sender.close()
    }

    @Test func theNotificationOwnerForwardsObservationsBeforeSendsAndEveryLockChange() async throws {
        let log = ForwardingLog(), lock = ReplyLock()
        let notifications = LockedCompletionNotifications(isLocked: { lock.value }, power: ReplyPower())
        notifications.configure(sender: ForwardingSender(log: log))
        let snapshot = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                          phase: .idle(completedTurnID: "turn_a")),
                                       project: "reply-project", title: "Synthetic task")
        notifications.receive(snapshot, baseline: false)
        try await waitUntil { log.events.contains("send") }
        lock.value = nil
        notifications.refreshLockState()
        lock.value = true
        notifications.refreshLockState()
        notifications.refreshLockState()
        // Unknown lock state never opens a reply window.
        #expect(log.events == ["locked", "observe", "send", "unlocked", "locked"])
        await notifications.shutdown()
    }
}
