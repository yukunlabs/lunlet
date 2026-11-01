// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-07, AC-07.05; US-08, AC-08.01, AC-08.03, AC-08.04, AC-08.05.
// Refs: US-09, AC-09.01, AC-09.02, AC-09.03; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02, AC-11.03, AC-11.05; US-12, AC-12.04.
// Refs: US-06, AC-06.02.
import Foundation
import LunletCore

/// Hands one claimed reply to the agent's input adapter and reports its outcome.
public typealias FeishuReplyDispatch = @Sendable (AuthorizedContinuation, ContinuationProgress) async -> ContinuationOutcome

/// Reply-capable Feishu completion cards for one enrollment. It owns the callback long connection,
/// which runs only while such a card is being prepared or is still within its validity period;
/// the reply window, which a confirmed locked Mac opens and unlocking closes; and session-named
/// receipts, shown in place on the replied card when the provider accepts the update. Every reply still passes the router (verified owner, bound message, freshness,
/// single-use token), the coordinator (one claim, current observation and connection) and the
/// dispatcher's live-binding checks. Nothing is retried.
public actor FeishuReplyService {
    private enum Event: Sendable {
        case observe(SessionSnapshot), window(Bool), owner(FeishuOwner)
        case flush(CheckedContinuation<Void, Never>)
    }
    private struct Connection {
        let token: UUID
        let task: Task<Void, Never>
    }
    /// A delivered reply-capable card whose reply box is kept truthful in place: disabled after one reply,
    /// then showing that reply's progress, or closed when the card can no longer take one.
    private struct Card {
        let messageID: String
        let sessionID: UUID
        let render: @Sendable (CardReplyState) throws -> FeishuCardDelivery
        let boundAt: ContinuousClock.Instant
        var state: CardReplyState
        /// Updates to one card run in order.
        var update: Task<Bool, Never>?
    }

    private let coordinator: MobileCoordinator
    private let router: CardActionRouter
    private let sender: any FeishuCardSending
    private let connect: @Sendable () -> any FeishuCallbackConnecting
    private let dispatch: FeishuReplyDispatch
    private let openTimeout: Duration
    private let checkInterval: Duration
    /// Observations, lock changes and the owner arrive in caller order through one stream.
    private nonisolated let events: AsyncStream<Event>.Continuation
    private nonisolated let consumer = TaskHandle()

    private var owner: FeishuOwner?
    private var replyWindow = false
    private var latest: [UUID: SessionSnapshot] = [:]
    private var connection: Connection?
    private var connectionID: UUID?
    /// A connection that failed for a non-retryable reason waits for a new enrollment.
    private var blocked = false
    private var preparing = 0
    private var unbound: [UUID: ContinuousClock.Instant] = [:]
    private var expiryCheck: Task<Void, Never>?
    // One entry per accepted reply for this enrollment, so a repeated handoff is never dispatched.
    private var handled: Set<UUID> = []
    private var cards: [UUID: Card] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private var closing: Task<Void, Never>?

    public init(sender: any FeishuCardSending, connect: @escaping @Sendable () -> any FeishuCallbackConnecting,
                dispatch: @escaping FeishuReplyDispatch) {
        self.init(sender: sender, connect: connect, dispatch: dispatch, router: CardActionRouter())
    }

    init(sender: any FeishuCardSending, connect: @escaping @Sendable () -> any FeishuCallbackConnecting,
         dispatch: @escaping FeishuReplyDispatch, router: CardActionRouter,
         openTimeout: Duration = .seconds(5), checkInterval: Duration = .seconds(30)) {
        self.router = router
        // Claims go through `claim`, so the coordinator's own handoff closure stays unused.
        coordinator = MobileCoordinator(sender: sender, router: router, onAction: { _ in })
        self.sender = sender
        self.connect = connect
        self.dispatch = dispatch
        self.openTimeout = openTimeout
        self.checkInterval = checkInterval
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        events = continuation
        consumer.set(Task { [weak self] in
            for await event in stream {
                guard let self else {
                    if case .flush(let done) = event { done.resume() }
                    continue
                }
                await self.apply(event)
            }
        })
    }

    deinit { events.finish() }

    /// Every live Codex root snapshot, in observation order.
    public nonisolated func observe(_ snapshot: SessionSnapshot) { events.yield(.observe(snapshot)) }

    /// Open only while the Mac is confirmed locked and phone replies are allowed.
    public nonisolated func setReplyWindow(_ open: Bool) { events.yield(.window(open)) }

    /// The first verified owner-bound send receipt establishes the owner and tenant; callbacks never do.
    public nonisolated func recordOwner(from receipt: FeishuMessageReceipt) {
        events.yield(.owner(FeishuOwner(applicationID: receipt.applicationID, tenantID: receipt.tenantID,
                                        userID: receipt.ownerID)))
    }

    /// An owner an earlier verified send receipt established for this same enrollment, kept with it so
    /// the first card after a relaunch can take replies. A later receipt never replaces it; a card whose
    /// receipt names another tenant fails to bind and takes no replies.
    public nonisolated func restoreOwner(_ owner: FeishuOwner) { events.yield(.owner(owner)) }

    /// A single-use reply capability for this completed Codex turn, or nil if any gate fails.
    /// Starts the callback connection if needed; the caller must bind or withdraw the result.
    public func prepareReply(for snapshot: SessionSnapshot) async -> FeishuReplyCapability? {
        await flush()
        let session = snapshot.observation.sessionID
        // Codex is the only agent with a validated original-CLI input path.
        guard !closed, !blocked, replyWindow, owner?.isComplete == true, snapshot.provider == .codex,
              snapshot.parentSessionID == nil, latest[session] == snapshot,
              case .idle = snapshot.observation.phase, snapshot.observation.liveness == .alive else { return nil }
        preparing += 1
        startConnectionIfNeeded()
        var capability: FeishuReplyCapability?
        if await waitForConnection(), !closed, replyWindow, latest[session] == snapshot {
            // Opening the connection reconfigured access, which requires a fresh observation. This
            // snapshot is still the newest local one, and dispatch rechecks the live binding.
            await coordinator.observe(snapshot)
            capability = await coordinator.prepareReply(for: snapshot)
            if let issued = capability, latest[session] != snapshot {
                await coordinator.withdrawReply(issued)
                if let newer = latest[session] { await coordinator.observe(newer) }
                capability = nil
            }
        }
        preparing -= 1
        if let capability { unbound[capability.token] = .now } else { await reevaluate() }
        return capability
    }

    /// Binds a sent card to its receipt; false means the card takes no replies. `card` renders that card in a
    /// reply state, so its box can be updated in place; without it, outcomes arrive as separate receipt cards.
    public func bindReply(_ capability: FeishuReplyCapability, receipt: FeishuMessageReceipt,
                          card render: (@Sendable (CardReplyState) throws -> FeishuCardDelivery)? = nil) async -> Bool {
        unbound.removeValue(forKey: capability.token)
        let bound = await coordinator.bindReply(capability, receipt: receipt)
        if let render, !closed {
            // A newer card for the same session replaces any older box still open.
            for (token, card) in cards where card.sessionID == capability.sessionID && card.state == .open {
                show(.closed(.superseded), on: token)
            }
            cards[capability.token] = Card(messageID: receipt.messageID, sessionID: capability.sessionID, render: render,
                                           boundAt: .now, state: .open)
            if !bound { show(.closed(await router.revocation(controlID: capability.token) ?? .unverified), on: capability.token) }
        }
        await reevaluate()
        return bound
    }

    /// Retires a capability whose card was not sent or did not carry the reply input.
    public func withdrawReply(_ capability: FeishuReplyCapability) async {
        unbound.removeValue(forKey: capability.token)
        await coordinator.withdrawReply(capability)
        await reevaluate()
    }

    /// Stops the connection, cancels in-flight work and closes the coordinator and its sender.
    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        events.finish()
        expiryCheck?.cancel(); expiryCheck = nil
        let pending = Array(work.values), updates = cards.values.compactMap(\.update)
        work.removeAll(); cards.removeAll()
        for task in pending { task.cancel() }
        for task in updates { task.cancel() }
        let task = Task {
            await stopConnection()
            for item in pending { await item.value }
            for item in updates { _ = await item.value }
            await coordinator.close()
            await consumer.value?.value
        }
        closing = task
        await task.value
    }

    var isConnected: Bool { connection != nil }

    private func apply(_ event: Event) async {
        switch event {
        case .flush(let done):
            done.resume()
        case .observe(let snapshot):
            guard !closed else { return }
            latest[snapshot.observation.sessionID] = snapshot
            await coordinator.observe(snapshot)
        case .window(let open):
            guard !closed, replyWindow != open else { return }
            replyWindow = open
            await coordinator.setReplyWindow(open)
            // Unlocking ends every open box; the cards say so instead of inviting a reply.
            if !open { for (token, card) in cards where card.state == .open { show(.closed(.replyWindowClosed), on: token) } }
            // Revoked cards keep the connection until they expire, so later taps get the reason.
            if !open { await reevaluate() }
        case .owner(let value):
            guard !closed, owner == nil, value.isComplete else { return }
            owner = value
            await configureCoordinator()
        }
    }

    private func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = events.yield(.flush(done)) { done.resume() }
        }
    }

    private func startConnectionIfNeeded() {
        guard connection == nil, !closed, !blocked else { return }
        connectionID = nil
        let token = UUID(), runner = connect(), router = router
        let task = Task { [weak self] in
            var failed = false
            do {
                try await runner.run(router: router,
                    onState: { [weak self] state in await self?.transport(state, token: token) },
                    onAction: { [weak self] action in Task { await self?.handle(action) } },
                    onRefusal: { [weak self] refusal in Task { await self?.report(refusal) } })
            } catch is CancellationError {
            } catch { failed = true }
            await self?.connectionEnded(token: token, failed: failed)
        }
        connection = Connection(token: token, task: task)
    }

    private func waitForConnection() async -> Bool {
        let deadline = ContinuousClock.now + openTimeout
        while !closed, !blocked, connection != nil {
            if connectionID != nil { return true }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return false
    }

    private func transport(_ state: FeishuTransportState, token: UUID) async {
        guard !closed, connection?.token == token else { return }
        let next: UUID?
        if case .socketOpen(let id) = state { next = id } else { next = nil }
        guard next != connectionID else { return }
        connectionID = next
        await configureCoordinator()
    }

    private func connectionEnded(token: UUID, failed: Bool) async {
        guard connection?.token == token else { return }
        connection = nil
        if failed { blocked = true }
        if connectionID != nil { connectionID = nil; await configureCoordinator() }
    }

    private func stopConnection() async {
        guard let current = connection else { return }
        connection = nil
        let wasOpen = connectionID != nil
        connectionID = nil
        current.task.cancel()
        if wasOpen { await configureCoordinator() }
        await current.task.value
    }

    private func configureCoordinator() async {
        // The open callback connection for this application is provisional callback evidence: if
        // the provider never delivers card actions on it, a reply simply never arrives.
        await coordinator.configure(owner: owner, connectionID: connectionID,
                                    callbacksVerified: connectionID != nil, adapterAvailable: true)
    }

    /// Stops the connection once no reply-capable card is being prepared or still valid.
    private func reevaluate() async {
        closeExpiredCards()
        guard connection != nil else { return }
        let outstanding = closed ? 0 : await router.outstandingCards()
        let now = ContinuousClock.now
        unbound = unbound.filter { now < $0.value + .seconds(ContinuationGate.controlLifetime) }
        if closed || (outstanding == 0 && unbound.isEmpty && preparing == 0) {
            expiryCheck?.cancel(); expiryCheck = nil
            await stopConnection()
        } else if expiryCheck == nil {
            let interval = checkInterval
            expiryCheck = Task { [weak self] in
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.expiryFired()
            }
        }
    }

    private func expiryFired() async {
        expiryCheck = nil
        await reevaluate()
    }

    private func handle(_ action: FeishuSocketAction) async {
        let receipt = action.continuation.receipt.id, session = action.continuation.session.sessionID
        guard !closed, handled.insert(receipt).inserted else { return }
        let token = await router.controlID(forReceipt: receipt)
        let text: String
        if case .followup(let value) = action.continuation.input { text = value } else { text = "" }
        guard await coordinator.claim(action) else {
            // Accepted by the router but no longer current: tell the owner why, once.
            let reason = await coordinator.recheck(action) ?? .unverified
            if !closed {
                track { [weak self] in await self?.conclude(.refused(reason), text: text, card: token, sessionID: session) }
            }
            return
        }
        guard !closed else {
            await coordinator.updateReceipt(receipt, status: .failed)
            return
        }
        // The box greys out at once, so the card never invites a second tap.
        if let token { show(.received(text), on: token) }
        track { [weak self] in await self?.run(action, text: text, card: token) }
    }

    private func run(_ action: FeishuSocketAction, text: String, card token: UUID?) async {
        let coordinator = coordinator, receipt = action.continuation.receipt.id
        let progress = ContinuationProgress(recheck: { await coordinator.recheck(action) }, submitted: { [weak self] in
            await coordinator.updateReceipt(receipt, status: .submitted)
            if let token { await self?.show(.submitted(text), on: token) }
        })
        let outcome = await dispatch(action.continuation, progress)
        switch outcome {
        case .delivered:
            await coordinator.updateReceipt(receipt, status: .submitted)
            await coordinator.updateReceipt(receipt, status: .processing)
        case .notConfirmed: await coordinator.updateReceipt(receipt, status: .uncertain)
        case .failed, .refused: await coordinator.updateReceipt(receipt, status: .failed)
        }
        guard !Task.isCancelled else { return }
        await conclude(outcome, text: text, card: token, sessionID: action.continuation.session.sessionID)
    }

    /// Shows a reply's outcome on its card, or sends a receipt card when the card cannot be updated.
    private func conclude(_ outcome: ContinuationOutcome, text: String, card token: UUID?, sessionID: UUID) async {
        if let token, let update = show(.finished(outcome, text), on: token), await update.value { return }
        await sendReceipt(outcome, sessionID: sessionID)
    }

    private func report(_ refusal: FeishuCardRefusal) {
        guard !closed else { return }
        if let token = refusal.controlID, let card = cards[token] {
            // A box Lunlet already closed answers with its toast; an open one now shows the reason.
            guard card.state == .open else { return }
            let update = show(.closed(refusal.reason), on: token)
            track { [weak self] in
                if await update?.value == true { return }
                await self?.sendReceipt(.refused(refusal.reason), sessionID: refusal.sessionID)
            }
            return
        }
        track { [weak self] in await self?.sendReceipt(.refused(refusal.reason), sessionID: refusal.sessionID) }
    }

    /// Replaces one bound card's content with `state`, after any earlier update to that card. The returned task
    /// reports whether the provider accepted the update; nil means the card is unknown or could not be rendered.
    @discardableResult
    private func show(_ state: CardReplyState, on token: UUID) -> Task<Bool, Never>? {
        guard !closed, var card = cards[token], let owner else { return nil }
        let delivery: FeishuCardDelivery
        do { delivery = try card.render(state) } catch { return nil }
        let previous = card.update, sender = sender, messageID = card.messageID
        let update = Task<Bool, Never> {
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            do { try await sender.updateCard(delivery, messageID: messageID, owner: owner); return true } catch { return false }
        }
        card.state = state
        card.update = update
        cards[token] = card
        return update
    }

    /// Open boxes past their validity say so; cards long past it are forgotten.
    private func closeExpiredCards() {
        let now = ContinuousClock.now, lifetime = Duration.seconds(ContinuationGate.controlLifetime)
        for (token, card) in cards where card.state == .open && now >= card.boundAt + lifetime {
            show(.closed(.expired), on: token)
        }
        cards = cards.filter { now < $0.value.boundAt + lifetime * 2 }
    }

    private func sendReceipt(_ outcome: ContinuationOutcome, sessionID: UUID) async {
        guard !closed, let owner else { return }
        do {
            let card = try ReplyReceiptCard.render(outcome, for: latest[sessionID])
            _ = try await sender.sendCard(card, owner: owner)
        } catch {
            // A receipt is informational; an uncertain send is never retried.
            FeishuDiagnostics.failure(.cardDelivery, operation: DiagnosticOperation(), error: error)
        }
    }

    private func track(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        work[id] = Task { [weak self] in
            await operation()
            await self?.finished(id)
        }
    }

    private func finished(_ id: UUID) { work.removeValue(forKey: id) }
}

/// Holds the event consumer so `close` can await it.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ value: Task<Void, Never>) { lock.withLock { task = value } }
    var value: Task<Void, Never>? { lock.withLock { task } }
}
