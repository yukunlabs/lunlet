// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03; US-10, AC-10.02, AC-10.04.
// Refs: US-14, AC-14.01.
import Foundation
import LunletCore

public enum CardCallbackFailure: Error, Equatable, Sendable {
    /// Not a supported, well-formed card submission.
    case malformed
    /// Another application, tenant or operator than the bound owner.
    case identity
    /// Outside the provider's three-second callback response window.
    case stale

    /// A fixed diagnostic category; callback contents are never logged.
    var diagnosticReason: DiagnosticReason {
        switch self {
        case .malformed: .protocolViolation
        case .identity: .authentication
        case .stale: .timeout
        }
    }
}

public enum CardFormValue: Equatable, Sendable, CustomStringConvertible {
    case text(String), selections([String])
    public var description: String { "Card form value (redacted)" }
}

/// Parsed provider data only; local authorization still belongs to ContinuationGate.
public struct CardCallback: Sendable, CustomStringConvertible {
    public let eventID: String
    public let controlID: UUID
    public let messageID: String
    public let chatID: String
    public let values: [String: CardFormValue]
    public var description: String { "Feishu card callback (redacted)" }

    /// Call only for payloads from the authenticated application long connection.
    /// This method does not verify a public webhook signature or Verification Token.
    public static func decodeFromLongConnection(_ data: Data, owner: FeishuOwner, now: Date) throws -> Self {
        let time = now.timeIntervalSince1970
        guard data.count <= 65_536, time.isFinite, time >= 0, time <= 253_402_300_799,
              let body = try? JSONDecoder().decode(Envelope.self, from: data),
              body.schema == "2.0", body.header.event_type == "card.action.trigger",
              validID(body.header.event_id) else { throw CardCallbackFailure.malformed }
        guard validID(owner.applicationID), validID(owner.tenantID), validID(owner.userID),
              body.header.app_id == owner.applicationID, body.header.tenant_key == owner.tenantID,
              body.event.operator.open_id == owner.userID,
              body.event.operator.tenant_key == owner.tenantID else { throw CardCallbackFailure.identity }
        guard body.event.host == "im_message", validID(body.event.context.open_message_id),
              validID(body.event.context.open_chat_id), body.event.action.tag == "button",
              body.event.action.name == "submit", body.event.action.value.count == 1,
              let rawControl = body.event.action.value["lunlet_control"], let control = UUID(uuidString: rawControl),
              !body.header.create_time.isEmpty, body.header.create_time.utf8.count <= 20,
              body.header.create_time.utf8.allSatisfy({ (48...57).contains($0) }),
              let microseconds = UInt64(body.header.create_time), microseconds > 0 else {
            throw CardCallbackFailure.malformed
        }
        // The provider's response window is the one deliberate wall-clock comparison;
        // control lifetimes stay monotonic in ContinuationGate.
        let age = time - TimeInterval(microseconds) / 1_000_000
        guard age >= -1, age < 3 else { throw CardCallbackFailure.stale }
        guard !body.event.action.form_value.isEmpty,
              body.event.action.form_value.count <= 8 else { throw CardCallbackFailure.malformed }
        var values: [String: CardFormValue] = [:]
        for (name, value) in body.event.action.form_value {
            guard validID(name, limit: 64) else { throw CardCallbackFailure.malformed }
            switch value {
            case .text(let text):
                guard validText(text) else { throw CardCallbackFailure.malformed }
            case .selections(let items):
                guard !items.isEmpty, items.count <= 20, Set(items).count == items.count,
                      items.allSatisfy(validText) else { throw CardCallbackFailure.malformed }
            }
            values[name] = value
        }
        return Self(eventID: body.header.event_id, controlID: control,
                    messageID: body.event.context.open_message_id, chatID: body.event.context.open_chat_id,
                    values: values)
    }

    /// Which check a malformed callback failed, as a number for the log and never its content (AC-14.01): 1 not a
    /// JSON object, 2 not schema 2.0, 3 not a card action, 4 no action, 5 not the submit button, 6 not exactly
    /// Lunlet's control value, 7 not a message card, 8 no or too many form values, 9 a finer check (an identifier,
    /// the time or a field's text).
    static func malformedStage(_ data: Data) -> Int {
        guard data.count <= 65_536, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 1 }
        guard body["schema"] as? String == "2.0", let header = body["header"] as? [String: Any] else { return 2 }
        guard header["event_type"] as? String == "card.action.trigger" else { return 3 }
        guard let event = body["event"] as? [String: Any], let action = event["action"] as? [String: Any] else { return 4 }
        guard action["tag"] as? String == "button", action["name"] as? String == "submit" else { return 5 }
        guard let value = action["value"] as? [String: Any], value.count == 1, value["lunlet_control"] is String else { return 6 }
        guard event["host"] as? String == "im_message", event["context"] is [String: Any] else { return 7 }
        guard let form = action["form_value"] as? [String: Any], !form.isEmpty, form.count <= 8 else { return 8 }
        return 9
    }

    private static func validID(_ value: String, limit: Int = 256) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func validText(_ value: String) -> Bool {
        value.utf8.count <= 8_192 && !value.contains("\0")
    }

    private struct Envelope: Decodable {
        let schema: String
        let header: Header
        let event: Event
        struct Header: Decodable {
            let event_id, create_time, event_type, tenant_key, app_id: String
        }
        struct Event: Decodable {
            let `operator`: Operator
            let host: String
            let context: Context
            let action: Action
        }
        struct Operator: Decodable { let tenant_key, open_id: String }
        struct Context: Decodable { let open_message_id, open_chat_id: String }
        struct Action: Decodable {
            let value: [String: String]
            let tag, name: String
            let form_value: [String: CardFormValue]
        }
    }
}

extension CardFormValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .selections(try value.decode([String].self)) }
    }
}
