// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04; US-10, AC-10.01, AC-10.02; US-06, AC-06.02; US-20, AC-20.03.
import Foundation
import LunletCore

/// What a notice's reply affordance shows: open for one reply, then that reply's progress or outcome, or
/// closed with the reason the notice can no longer take one.
public enum NoticeReplyState: Equatable, Sendable {
    case open
    /// The owner's reply was accepted and is being handed to the agent.
    case received(String)
    /// The agent accepted the reply; the session record has not shown it yet.
    case submitted(String)
    case finished(ContinuationOutcome, String)
    /// No reply was sent from this notice, and none can be.
    case closed(ContinuationRefusal)
}

/// The owner's reply to one notice, as the provider delivered it. `messageID` is the reply's own provider
/// identity and `repliedTo` the notice it answers; both come from the provider, never from the text.
public struct BotReply: Equatable, Sendable {
    public let messageID: String
    public let repliedTo: String
    public let text: String
    public let sentAt: Date
    public init(messageID: String, repliedTo: String, text: String, sentAt: Date) {
        self.messageID = messageID; self.repliedTo = repliedTo; self.text = text; self.sentAt = sentAt
    }
}

/// The reply lines every channel shows under a notice, in the same words as the Feishu card.
public enum NoticeReplyText {
    public static let maximumCharacters = 1_000
    /// How the channel takes a reply: Telegram's button opens a reply box, Slack takes a reply in the thread.
    public static func hint(_ channel: BotChannel) -> String {
        let minutes = Int(ContinuationGate.controlLifetime / 60)
        switch channel {
        case .telegram: return "Reply within \(minutes) min while your Mac stays locked to continue this session."
        case .slack: return "Reply in this thread within \(minutes) min while your Mac stays locked to continue this session."
        }
    }
    /// The Telegram button under an open notice.
    public static let replyButton = "↩ Reply to continue"
    /// The Telegram prompt whose reply box the button opens; the owner answers it.
    public static func prompt(agent: String) -> String { "Reply to this message to continue \(agent)." }
    public static func placeholder(agent: String) -> String { "Your reply to \(agent)" }
    /// The label and detail of a state after `open`; nil for an open notice.
    public static func status(_ state: NoticeReplyState, agent: String) -> (label: String, detail: String)? {
        switch state {
        case .open: return nil
        case .received: return ("Received", "sending to \(agent)…")
        case .submitted: return ("Sent", "waiting for \(agent) to start")
        case .finished(.delivered, _): return ("Delivered", "\(agent) is continuing on your Mac")
        case .finished(.notConfirmed, _): return ("Not confirmed", "\(agent) hasn't confirmed it. Check your Mac; Lunlet won't send it again.")
        case .finished(.failed, _): return ("Not sent", "Continue on your Mac.")
        case .finished(.refused(let reason), _): return ("Not sent", reason.explanation)
        case .closed(let reason): return ("Replies closed", reason.explanation)
        }
    }
}

/// What the paired owner did with a notice: replied to one of the bot's messages, or tapped its reply button.
public enum BotReplyEvent: Equatable, Sendable {
    case reply(BotReply)
    /// The owner asked to reply to the notice `messageID`; `callbackID` identifies the tap to the provider.
    case replyRequested(messageID: String, callbackID: String)
}

/// Hands one claimed reply to the agent's input adapter and reports its outcome.
public typealias BotReplyDispatch = @Sendable (AuthorizedContinuation, ContinuationProgress) async -> ContinuationOutcome

/// A bot transport that also takes replies: it sends a notice with or without a reply affordance, rewrites it with
/// the reply's state, receives the paired owner's replies and reply requests, and sends a plain fallback line.
public protocol ChannelReplyClient: ChannelBotClient {
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) async throws -> BotMessageReceipt
    func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) async throws
    /// Delivers each reply and reply request from the paired owner until cancelled or closed.
    func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws
    /// Answers a reply request: with `refusal` nil it opens the owner's reply box for `agent` and returns the ID
    /// of the message the owner will answer, otherwise it shows the refusal and returns nil. Channels whose
    /// notices take replies without a request return nil.
    func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) async throws -> String?
    func sendText(_ text: String, binding: BotBinding) async throws
}

public extension ChannelReplyClient {
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding) async throws -> BotMessageReceipt {
        try await sendCompletion(snapshot, binding: binding, reply: nil)
    }
}
