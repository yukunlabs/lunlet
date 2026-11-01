// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.05, AC-01.08; US-05, AC-05.06, AC-05.09; US-06, AC-06.01, AC-06.02, AC-06.05.
// Refs: US-08, AC-08.01, AC-08.04, AC-08.05; US-10, AC-10.01, AC-10.04.
import LunletCore
import LunletFeishu

/// The owner-bound client operations a completion sender needs.
protocol FeishuCompletionClient: FeishuCardSending {
    func sendCard(_ delivery: FeishuCardDelivery) async throws -> FeishuMessageReceipt
    func checkAuthorization() async throws
}
extension FeishuBotClient: FeishuCompletionClient {}

/// Renders one completion card, with its reply box in a given state. A renderer that appends the reply input
/// for a capability follows `FeishuReplyCapability`'s callback contract and declares `embedsReplies`; without
/// one, no capability is ever issued and no callback connection is opened.
struct FeishuCompletionCardRenderer: Sendable {
    let embedsReplies: Bool
    let render: @Sendable (SessionSnapshot, FeishuReplyCapability?, CardReplyState) throws -> FeishuCardDelivery

    /// The completion card, with a reply box at its end whenever the reply service issued a capability.
    static let current = FeishuCompletionCardRenderer(embedsReplies: true) { snapshot, reply, state in
        try SessionCard.render(snapshot, reply: reply, replyState: state).delivery
    }
}

/// The notification coordinator owns this sender. It sends to the owner returned by registration
/// and verifies the provider's receipt. Reply controls exist only with a reply-capable renderer and
/// an input adapter, and then only through the reply service's gates.
actor FeishuCompletionSender: CompletionNotificationSending {
    private let client: any FeishuCompletionClient
    private let renderer: FeishuCompletionCardRenderer
    private let replies: FeishuReplyService?
    private let remember: @Sendable (FeishuOwner) -> Void
    private var verifiedOwner: FeishuOwner?

    init(enrollment: FeishuEnrollment, dispatch: FeishuReplyDispatch? = nil,
         renderer: FeishuCompletionCardRenderer = .current, memory: FeishuOwnerMemory = FeishuOwnerMemory()) {
        let client = FeishuBotClient(enrollment: enrollment)
        self.init(client: client, renderer: renderer, dispatch: dispatch,
                  connect: { FeishuConnectionRunner(client: client) },
                  owner: memory.owner(for: enrollment), remember: { memory.remember($0) })
    }

    /// `owner` is one an earlier verified receipt established for this same enrollment; `remember`
    /// keeps each newly verified one.
    init(client: any FeishuCompletionClient, renderer: FeishuCompletionCardRenderer, dispatch: FeishuReplyDispatch?,
         connect: @escaping @Sendable () -> any FeishuCallbackConnecting,
         owner: FeishuOwner? = nil, remember: @escaping @Sendable (FeishuOwner) -> Void = { _ in }) {
        self.client = client
        self.renderer = renderer
        self.remember = remember
        verifiedOwner = owner
        replies = renderer.embedsReplies
            ? dispatch.map { FeishuReplyService(sender: client, connect: connect, dispatch: $0) } : nil
        if let owner { replies?.restoreOwner(owner) }
    }

    func send(_ snapshot: SessionSnapshot) async throws {
        var capability = await replies?.prepareReply(for: snapshot)
        let delivery: FeishuCardDelivery
        let receipt: FeishuMessageReceipt
        do {
            delivery = try renderer.render(snapshot, capability, .open)
            receipt = try await client.sendCard(delivery)
        } catch {
            // An unsent or uncertain card never keeps a usable control.
            if let capability { await replies?.withdrawReply(capability) }
            throw error
        }
        let owner = FeishuOwner(applicationID: receipt.applicationID, tenantID: receipt.tenantID, userID: receipt.ownerID)
        if owner != verifiedOwner { verifiedOwner = owner; remember(owner) }
        replies?.recordOwner(from: receipt)
        if capability == nil, let replies {
            // The first card after a new enrollment goes out before any receipt has verified the owner. This
            // receipt has, so the same card gains its reply box in place; a refused update leaves no control.
            if let issued = await replies.prepareReply(for: snapshot) {
                do {
                    try await client.updateCard(try renderer.render(snapshot, issued, .open), messageID: receipt.messageID, owner: owner)
                    capability = issued
                } catch {
                    await replies.withdrawReply(issued)
                }
            }
        }
        if let capability {
            // The same card, re-rendered, shows the reply box's later states in place.
            let renderer = renderer
            _ = await replies?.bindReply(capability, receipt: receipt) { try renderer.render(snapshot, capability, $0) }
        }
    }

    nonisolated func observe(_ snapshot: SessionSnapshot) {
        guard snapshot.provider == .codex, snapshot.parentSessionID == nil else { return }
        replies?.observe(snapshot)
    }

    /// Phone replies are allowed by default (AC-05.08), so the reply window follows the lock state.
    nonisolated func lockChanged(_ locked: Bool) { replies?.setReplyWindow(locked) }

    func checkAuthorization() async throws { try await client.checkAuthorization() }

    func close() async {
        await replies?.close()
        await client.close()
    }
}
