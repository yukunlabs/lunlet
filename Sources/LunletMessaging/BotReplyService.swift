// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04; US-05, AC-05.09; US-08, AC-08.03, AC-08.04, AC-08.05.
// Refs: US-09, AC-09.01, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04; US-11, AC-11.03; US-12, AC-12.04.
import Foundation
import LunletCore

/// Reply-capable Slack and Telegram notices for one paired bot. It issues one single-use control per eligible
/// Codex completion while the Mac is locked, listens for the owner's replies to those notices only while one can
/// still take a reply, hands an accepted reply to the agent's input adapter and keeps the notice truthful in
/// place: received, sent, delivered, or why not. Every reply passes the continuation gate (paired owner, bound
/// notice, freshness, single use), the recheck of the live session and the adapter's own binding checks.
/// Nothing is retried.
public actor BotReplyService {
    private struct Notice {
        let messageID: String
        let sessionID: UUID
        let snapshot: SessionSnapshot
        let issued: ObservedSession
        let boundAt: TimeInterval
        var state: NoticeReplyState
        /// Updates to one notice run in order.
        var update: Task<Bool, Never>?
    }
    private enum Event: Sendable {
        case observe(SessionSnapshot), window(Bool)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let client: any ChannelReplyClient
    private let binding: BotBinding
    private let dispatch: BotReplyDispatch
    private let elapsed: @Sendable () -> TimeInterval
    private let checkInterval: Duration
    private let gate = ContinuationGate()
    /// Observations and lock changes arrive in caller order through one stream, so a later snapshot never lands
    /// before an earlier one and a notice is prepared against the newest observation.
    private nonisolated let events: AsyncStream<Event>.Continuation
    private nonisolated let consumer = TaskHandle()
    private var replyWindow = false
    private var latest: [UUID: SessionSnapshot] = [:]
    private var notices: [UUID: Notice] = [:]
    /// Prompt messages opened by the reply button, by their message ID, to the notice they belong to.
    private var prompts: [String: UUID] = [:]
    private var listener: Task<Void, Never>?
    private var listenerFailures = 0
    private var handled: Set<String> = []
    private var work: [UUID: Task<Void, Never>] = [:]
    private var expiryCheck: Task<Void, Never>?
    private var closed = false

    public init(client: any ChannelReplyClient, binding: BotBinding, dispatch: @escaping BotReplyDispatch,
                elapsed: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                checkInterval: Duration = .seconds(30)) {
        self.client = client
        self.binding = binding
        self.dispatch = dispatch
        self.elapsed = elapsed
        self.checkInterval = checkInterval
        gate.setAccess(.init(owner: FeishuOwner(applicationID: binding.botID, tenantID: binding.chatID, userID: binding.ownerID),
                             connected: true, awayMode: false, inputEnabled: true))
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

    /// The paired bot, chat and owner from the enrollment are the only identity a reply can carry.
    private var owner: FeishuOwner { FeishuOwner(applicationID: binding.botID, tenantID: binding.chatID, userID: binding.ownerID) }
    private var access: MobileAccess { .init(owner: owner, connected: true, awayMode: replyWindow, inputEnabled: true) }
    private var component: DiagnosticComponent { binding.channel == .slack ? .slack : .telegram }

    /// Every live Codex root snapshot, in observation order.
    public nonisolated func observe(_ snapshot: SessionSnapshot) { events.yield(.observe(snapshot)) }

    /// Open only while the Mac is confirmed locked; closing it ends every open notice.
    public nonisolated func setReplyWindow(_ open: Bool) { events.yield(.window(open)) }

    private func apply(_ event: Event) {
        switch event {
        case .flush(let done):
            done.resume()
        case .observe(let snapshot):
            guard !closed else { return }
            latest[snapshot.observation.sessionID] = snapshot
            gate.observe(snapshot.observation)
        case .window(let open):
            guard !closed, replyWindow != open else { return }
            replyWindow = open
            // Changing access invalidates every observation, so the gate learns the current sessions again.
            gate.setAccess(access)
            for snapshot in latest.values { gate.observe(snapshot.observation) }
            if !open { for (id, notice) in notices where notice.state == .open { show(.closed(.replyWindowClosed), on: id) } }
            reevaluate()
        }
    }

    /// Applies every observation and lock change yielded so far.
    private func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = events.yield(.flush(done)) { done.resume() }
        }
    }

    /// A single-use control for this completed Codex turn, or nil if any gate fails; the caller binds or withdraws it.
    public func prepareReply(for snapshot: SessionSnapshot) async -> ContinuationControl? {
        await flush()
        let session = snapshot.observation.sessionID
        guard !closed, replyWindow, snapshot.provider == .codex, snapshot.parentSessionID == nil, latest[session] == snapshot,
              case .idle = snapshot.observation.phase, snapshot.observation.liveness == .alive else { return nil }
        return gate.issueControl(for: session, now: elapsed())
    }

    /// Binds a sent notice to its control, so replies to that message can use it; a newer notice for the same
    /// session closes any older one still open.
    public func bindReply(_ control: ContinuationControl, receipt: BotMessageReceipt, snapshot: SessionSnapshot) {
        guard !closed else { return }
        let session = snapshot.observation.sessionID
        for (id, notice) in notices where notice.sessionID == session && notice.state == .open { show(.closed(.superseded), on: id) }
        notices[control.id] = Notice(messageID: receipt.messageID, sessionID: session, snapshot: snapshot,
                                     issued: snapshot.observation, boundAt: elapsed(), state: .open)
        startListenerIfNeeded()
        scheduleExpiryCheck()
    }

    /// Retires a control whose notice was not sent.
    public func withdrawReply(_ control: ContinuationControl) {
        gate.withdraw(controlID: control.id)
        reevaluate()
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        events.finish()
        expiryCheck?.cancel(); expiryCheck = nil
        let pending = Array(work.values), updates = notices.values.compactMap(\.update), current = listener
        work.removeAll(); notices.removeAll(); listener = nil
        current?.cancel()
        for task in pending { task.cancel() }
        for task in updates { task.cancel() }
        // Quitting never waits on a provider: each cancelled task gets a few seconds to wind down, no more.
        await Self.settle(current)
        for task in pending { await Self.settle(task) }
        for task in updates { await Self.settle(task) }
        await Self.settle(consumer.value)
    }

    /// Waits for a cancelled task, but at most `limit`.
    private static func settle<Value: Sendable>(_ task: Task<Value, Never>?, limit: Duration = .seconds(3)) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    var isListening: Bool { listener != nil }

    // MARK: - Replies

    private func handle(_ event: BotReplyEvent) async {
        switch event {
        case .reply(let reply): await handle(reply)
        case .replyRequested(let messageID, let callbackID): await requested(messageID, callbackID: callbackID)
        }
    }

    /// The reply button opens the owner's reply box while the notice can still take a reply, otherwise it says why not.
    private func requested(_ messageID: String, callbackID: String) async {
        guard !closed, handled.insert("tap:" + callbackID).inserted,
              let (id, notice) = notices.first(where: { $0.value.messageID == messageID }) else { return }
        let refusal: String?
        if notice.state == .open, elapsed() < notice.boundAt + ContinuationGate.controlLifetime, replyWindow { refusal = nil }
        else { refusal = "Not sent. " + self.refusal(for: notice).explanation }
        let agent = notice.snapshot.provider.displayName, client = client, binding = binding
        do {
            if let prompt = try await client.promptReply(callbackID: callbackID, agent: agent, refusal: refusal, binding: binding) {
                prompts[prompt] = id
            }
        } catch {
            DiagnosticLog.record(.cardDelivery, component: component, outcome: .failed, operation: DiagnosticOperation(), reason: .provider)
        }
    }

    private func handle(_ reply: BotReply) async {
        guard !closed, handled.insert(reply.messageID).inserted else { return }
        let target = prompts[reply.repliedTo] ?? notices.first { $0.value.messageID == reply.repliedTo }?.key
        guard let id = target, let notice = notices[id] else { return }
        guard reply.text.count <= NoticeReplyText.maximumCharacters, ContinuationText.isForwardable(reply.text) else {
            await fallback("Not sent. Keep a reply under \(NoticeReplyText.maximumCharacters) characters of plain text.")
            return
        }
        switch gate.submit(controlID: id, callbackID: reply.messageID, owner: owner, input: .followup(reply.text), now: elapsed()) {
        case .accepted(let action):
            // The notice says so at once, so it never invites a second reply.
            show(.received(reply.text), on: id)
            track { [weak self] in await self?.run(action, text: reply.text, notice: id) }
        case .duplicate:
            return
        case .rejected:
            let reason = refusal(for: notice)
            DiagnosticLog.record(.cardAction, component: .continuation, outcome: .rejected, operation: DiagnosticOperation(),
                                 reason: .init(reason))
            if notice.state == .open, let update = show(.closed(reason), on: id), await update.value { return }
            await fallback("Not sent. " + reason.explanation)
        }
    }

    /// Why a notice no longer takes a reply, in the words the owner sees.
    private func refusal(for notice: Notice) -> ContinuationRefusal {
        switch notice.state {
        case .closed(let reason): return reason
        case .received, .submitted, .finished: return .alreadySent
        case .open: break
        }
        guard replyWindow else { return .replyWindowClosed }
        guard elapsed() < notice.boundAt + ContinuationGate.controlLifetime else { return .expired }
        return ContinuationRefusal.classify(issued: notice.issued, current: latest[notice.sessionID]?.observation)
    }

    private func run(_ action: AuthorizedContinuation, text: String, notice id: UUID) async {
        let receipt = action.receipt.id
        // A passing recheck is nil, so it is never folded into the refusal a released service would give.
        let progress = ContinuationProgress(recheck: { [weak self] in
            guard let self else { return .unverified }
            return await self.recheck(action)
        }, submitted: { [weak self] in await self?.submitted(receipt, text: text, notice: id) })
        let outcome = await dispatch(action, progress)
        switch outcome {
        case .delivered:
            gate.updateReceipt(receipt, status: .submitted)
            gate.updateReceipt(receipt, status: .processing)
        case .notConfirmed: gate.updateReceipt(receipt, status: .uncertain)
        case .failed, .refused: gate.updateReceipt(receipt, status: .failed)
        }
        guard !Task.isCancelled, !closed else { return }
        if let update = show(.finished(outcome, text), on: id), await update.value { return }
        if let status = NoticeReplyText.status(.finished(outcome, text), agent: notices[id]?.snapshot.provider.displayName ?? "the agent") {
            await fallback(status.label + ". " + status.detail)
        }
    }

    private func recheck(_ action: AuthorizedContinuation) -> ContinuationRefusal? {
        guard replyWindow else { return .replyWindowClosed }
        guard let current = latest[action.session.sessionID]?.observation else { return .unverified }
        return current == action.session ? nil : ContinuationRefusal.classify(issued: action.session, current: current)
    }

    private func submitted(_ receipt: UUID, text: String, notice id: UUID) {
        gate.updateReceipt(receipt, status: .submitted)
        show(.submitted(text), on: id)
    }

    /// Rewrites one notice with `state`, after any earlier update to it. The task reports whether the provider
    /// accepted the edit; nil means the notice is unknown.
    @discardableResult
    private func show(_ state: NoticeReplyState, on id: UUID) -> Task<Bool, Never>? {
        guard !closed, var notice = notices[id] else { return nil }
        let previous = notice.update, client = client, binding = binding, component = component
        let snapshot = notice.snapshot, messageID = notice.messageID
        let update = Task<Bool, Never> {
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            let operation = DiagnosticOperation()
            DiagnosticLog.record(.cardUpdate, component: component, outcome: .started, operation: operation)
            do {
                try await client.updateCompletion(snapshot, binding: binding, messageID: messageID, reply: state)
                DiagnosticLog.record(.cardUpdate, component: component, outcome: .completed, operation: operation)
                return true
            } catch {
                DiagnosticLog.record(.cardUpdate, component: component, outcome: Task.isCancelled ? .cancelled : .failed,
                                     operation: operation, reason: .provider)
                return false
            }
        }
        notice.state = state
        notice.update = update
        notices[id] = notice
        return update
    }

    /// A plain line in the chat when the notice itself cannot be rewritten; informational, never retried.
    private func fallback(_ text: String) async {
        guard !closed else { return }
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.cardDelivery, component: component, outcome: .started, operation: operation)
        do {
            try await client.sendText(text, binding: binding)
            DiagnosticLog.record(.cardDelivery, component: component, outcome: .completed, operation: operation)
        } catch {
            DiagnosticLog.record(.cardDelivery, component: component, outcome: .failed, operation: operation, reason: .provider)
        }
    }

    // MARK: - Listener lifetime

    /// Replies are received only while a notice is within its validity period.
    private var needsListener: Bool {
        let now = elapsed()
        return notices.values.contains { now < $0.boundAt + ContinuationGate.controlLifetime }
    }

    private func startListenerIfNeeded() {
        guard listener == nil, !closed, listenerFailures < 5, needsListener else { return }
        let client = client, binding = binding
        listener = Task { [weak self] in
            var failed = false
            do {
                try await client.receiveReplies(binding: binding) { [weak self] event in await self?.handle(event) }
            } catch is CancellationError {
            } catch let failure as BotChannelFailure where failure == .canceled {
            } catch { failed = true }
            await self?.listenerEnded(failed: failed)
        }
    }

    private func listenerEnded(failed: Bool) async {
        listener = nil
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.connection, component: component, outcome: failed ? .failed : .stopped, operation: operation,
                             reason: failed ? .network : .none)
        listenerFailures = failed ? listenerFailures + 1 : 0
        guard !closed, needsListener else { return }
        if failed {
            // A provider that keeps failing is left alone until a new notice is bound.
            do { try await Task.sleep(for: .seconds(min(10, listenerFailures * 2))) } catch { return }
            guard !closed, needsListener else { return }
        }
        startListenerIfNeeded()
    }

    private func reevaluate() {
        closeExpiredNotices()
        if !needsListener {
            listener?.cancel()
            expiryCheck?.cancel(); expiryCheck = nil
        }
    }

    private func scheduleExpiryCheck() {
        guard expiryCheck == nil, !closed else { return }
        let interval = checkInterval
        expiryCheck = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            await self?.expiryFired()
        }
    }

    private func expiryFired() {
        expiryCheck = nil
        guard !closed else { return }
        reevaluate()
        if needsListener { scheduleExpiryCheck() }
    }

    /// Open notices past their validity say so; notices long past it are forgotten.
    private func closeExpiredNotices() {
        let now = elapsed(), lifetime = ContinuationGate.controlLifetime
        for (id, notice) in notices where notice.state == .open && now >= notice.boundAt + lifetime {
            show(.closed(.expired), on: id)
        }
        notices = notices.filter { now < $0.value.boundAt + lifetime * 2 }
        prompts = prompts.filter { notices[$0.value] != nil }
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

private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ value: Task<Void, Never>) { lock.withLock { task = value } }
    var value: Task<Void, Never>? { lock.withLock { task } }
}
