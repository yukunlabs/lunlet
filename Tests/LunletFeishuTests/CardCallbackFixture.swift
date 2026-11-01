// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03; US-10, AC-10.02, AC-10.04.
import Foundation
import LunletCore

enum CardCallbackFixture {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let owner = FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_owner")
    static let controlID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static func body(control: UUID = controlID, event: String = "event_synthetic",
                     values: [String: Any] = ["followup": "Continue the synthetic task"]) -> [String: Any] {
        ["schema": "2.0", "header": [
            "event_id": event, "token": "synthetic-verification-token", "create_time": "1800000000000000",
            "event_type": "card.action.trigger", "tenant_key": "tenant_synthetic", "app_id": "cli_synthetic",
        ], "event": [
            "operator": ["tenant_key": "tenant_synthetic", "open_id": "ou_owner"],
            "token": "synthetic-card-update-token", "host": "im_message",
            "action": ["value": ["lunlet_control": control.uuidString], "tag": "button",
                       "name": "submit", "form_value": values],
            "context": ["open_message_id": "om_synthetic", "open_chat_id": "oc_synthetic"],
        ]]
    }

    static func data(control: UUID = controlID, event: String = "event_synthetic",
                     values: [String: Any] = ["followup": "Continue the synthetic task"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body(control: control, event: event, values: values))
    }
}
