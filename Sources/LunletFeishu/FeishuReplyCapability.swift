// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-07, AC-07.05; US-08, AC-08.01, AC-08.05; US-10, AC-10.02, AC-10.04.
import Foundation

/// What a completion-card renderer needs to append a reply input for one completed Codex turn.
/// The token is single-use and targets only this session and turn. It stops working when the
/// Mac unlocks or at `expiresAt`, whichever is first, and authorizes nothing by itself: every
/// submission still passes the owner, message, freshness and live-binding checks.
///
/// Callback contract enforced by `CardCallback` and `CardForm`: a JSON 2.0 `form` container
/// named `formName` holding exactly one `input` named `fieldName` (plain text, required, at most
/// `maximumCharacters`) and one `button` named `buttonName` with `form_action_type: "submit"` and
/// a single `callback` behavior whose value is exactly `callbackValue`. Any other field, value
/// or action is rejected.
public struct FeishuReplyCapability: Equatable, Sendable, CustomStringConvertible {
    public static let formName = "continuation"
    public static let fieldName = "followup"
    public static let buttonName = "submit"
    public static let controlKey = "lunlet_control"
    public static let maximumCharacters = 1_000

    public let token: UUID
    public let sessionID: UUID
    public let turnID: String
    /// A wall-clock hint for display only; validity is enforced monotonically and by the lock state.
    public let expiresAt: Date

    /// The submit button's callback value.
    public var callbackValue: [String: String] { [Self.controlKey: token.uuidString] }
    public var description: String { "Feishu reply capability (redacted)" }

    public init(token: UUID, sessionID: UUID, turnID: String, expiresAt: Date) {
        self.token = token
        self.sessionID = sessionID
        self.turnID = turnID
        self.expiresAt = expiresAt
    }
}
