// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.03, AC-08.04; US-09, AC-09.01; US-10, AC-10.01, AC-10.03.
// Refs: US-05, AC-05.08, AC-05.09; US-11, AC-11.02, AC-11.03.
import Foundation
import LunletCore

/// A short receipt for one reply, sent to the verified owner and naming the session it was bound
/// to (AC-08.04). It carries plain text only and no controls.
public enum ReplyReceiptCard {
    public static func render(_ outcome: ContinuationOutcome, for snapshot: SessionSnapshot?) throws -> FeishuCardDelivery {
        let notice = snapshot.map(SessionNotice.prepare)
        let project = notice?.project ?? "Codex"
        let title = notice?.title ?? "this session"
        let template: String
        switch outcome {
        case .delivered: template = "green"
        case .notConfirmed: template = "orange"
        case .failed, .refused: template = "grey"
        }
        let body: [String: Any] = [
            "schema": "2.0",
            "header": ["title": plain(project), "subtitle": plain((notice?.agent ?? "Codex") + " · " + title),
                       "template": template],
            "body": ["elements": [["tag": "div", "text": plain(message(outcome, title: title))]]],
        ]
        return try FeishuCardDelivery(cardJSON: JSONSerialization.data(withJSONObject: body))
    }

    static func message(_ outcome: ContinuationOutcome, title: String) -> String {
        switch outcome {
        case .delivered: "Delivered to \(title) · continuing on your Mac"
        case .notConfirmed: "Sent to \(title), but delivery is not confirmed — check on your Mac. Lunlet will not send it again."
        case .failed: "Not delivered to \(title) — continue on your Mac."
        case .refused(let reason): "Not sent to \(title). " + reason.explanation
        }
    }

    private static func plain(_ content: String) -> [String: String] { ["tag": "plain_text", "content": content] }
}
