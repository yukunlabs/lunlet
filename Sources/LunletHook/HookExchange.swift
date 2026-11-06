// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.03, AC-38.05.
import Foundation

/// What Claude Code hands a Stop hook on its standard input, reduced to the fields the helper uses.
public struct HookInput: Equatable, Sendable {
    public let sessionID: UUID
    public let promptID: String?
    public let lastAssistantMessage: String
    public let stopHookActive: Bool

    /// Nil for anything but a Stop event with a session id; the helper then exits without a word.
    public init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "Stop",
              let session = (object["session_id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        sessionID = session
        promptID = (object["prompt_id"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
        lastAssistantMessage = object["last_assistant_message"] as? String ?? ""
        stopHookActive = object["stop_hook_active"] as? Bool ?? false
    }
}

/// What the helper prints to continue the session with the owner's follow-up: Claude Code's documented
/// non-error form, which the transcript labels hook feedback and which triggers no error notice.
public enum HookOutput {
    /// Names the owner's follow-up for the model; the delivery watch recognizes it in the transcript.
    public static let followupPrefix = "The user sent this follow-up from their phone through Lunlet. Treat it exactly as their next message and continue:\n"

    public static func continuation(text: String) -> Data {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": followupPrefix + text]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// The follow-up inside a recorded hook context, or nil when the text is not Lunlet's.
    public static func followup(in context: String) -> String? {
        guard context.hasPrefix(followupPrefix) else { return nil }
        return String(context.dropFirst(followupPrefix.count))
    }
}
