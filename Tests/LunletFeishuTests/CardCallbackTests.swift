// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03; US-10, AC-10.02, AC-10.04.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

struct CardCallbackTests {
    @Test func decodesMicrosecondTimestampsAndTypedValuesWithoutRetainingProviderTokens() throws {
        let input = try CardCallbackFixture.data(values: ["answer_0": "café ✓", "answer_1": ["one", "two"]])
        let callback = try CardCallback.decodeFromLongConnection(input, owner: CardCallbackFixture.owner,
                                                                 now: CardCallbackFixture.date)
        #expect(callback.eventID == "event_synthetic")
        #expect(callback.controlID == CardCallbackFixture.controlID)
        #expect(callback.messageID == "om_synthetic")
        #expect(callback.chatID == "oc_synthetic")
        #expect(callback.values == ["answer_0": .text("café ✓"), "answer_1": .selections(["one", "two"])])
        #expect(!String(describing: callback).contains("café"))
        #expect(!String(describing: callback.values).contains("café"))
    }

    @Test(arguments: ["app_id", "tenant_key", "operator_tenant", "open_id"])
    func rejectsEveryMismatchedApplicationAndOwnerIdentity(_ field: String) throws {
        var body = CardCallbackFixture.body()
        if field == "app_id" || field == "tenant_key" {
            var header = body["header"] as! [String: Any]
            header[field] = "other_identity"
            body["header"] = header
        } else {
            var event = body["event"] as! [String: Any]
            var actor = event["operator"] as! [String: Any]
            actor[field == "operator_tenant" ? "tenant_key" : "open_id"] = "other_identity"
            event["operator"] = actor
            body["event"] = event
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(throws: CardCallbackFailure.identity) {
            try CardCallback.decodeFromLongConnection(data, owner: CardCallbackFixture.owner, now: CardCallbackFixture.date)
        }
    }

    @Test(arguments: ["1800000000000", "1800000000", "1800000061000000", "1799999400000000", "1799999996000000", "1800000002000000", "NaN", "-1"])
    func staleFutureAndWrongUnitTimestampsCannotReachLocalAuthorization(_ timestamp: String) throws {
        var body = CardCallbackFixture.body()
        var header = body["header"] as! [String: Any]
        header["create_time"] = timestamp
        body["header"] = header
        let data = try JSONSerialization.data(withJSONObject: body)
        // Non-decimal values are malformed; decimal values outside the provider window are stale.
        let expected = timestamp.allSatisfy(\.isNumber) ? CardCallbackFailure.stale : .malformed
        #expect(throws: expected) {
            try CardCallback.decodeFromLongConnection(data, owner: CardCallbackFixture.owner, now: CardCallbackFixture.date)
        }
    }

    @Test(arguments: ["schema", "event_type", "host", "tag", "name", "context", "control", "value"])
    func unsupportedCallbackShapesCannotBeTreatedAsSubmittedForms(_ variant: String) throws {
        var body = CardCallbackFixture.body()
        var header = body["header"] as! [String: Any]
        var event = body["event"] as! [String: Any]
        var action = event["action"] as! [String: Any]
        switch variant {
        case "schema": body["schema"] = "1.0"
        case "event_type": header["event_type"] = "im.message.receive_v1"
        case "host": event["host"] = "url_preview"
        case "tag": action["tag"] = "input"
        case "name": action["name"] = "reset"
        case "context": event.removeValue(forKey: "context")
        case "control": action["value"] = ["lunlet_control": "not-a-uuid"]
        default: action["value"] = ["lunlet_control": CardCallbackFixture.controlID.uuidString, "session": "untrusted"]
        }
        body["header"] = header
        event["action"] = action
        body["event"] = event
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(throws: CardCallbackFailure.malformed) {
            try CardCallback.decodeFromLongConnection(data, owner: CardCallbackFixture.owner, now: CardCallbackFixture.date)
        }
    }

    @Test(arguments: ["number", "boolean", "mixed_array", "object", "oversized"])
    func malformedOrOversizedFormValuesAreRejected(_ variant: String) throws {
        let value: Any
        switch variant {
        case "number": value = 42
        case "boolean": value = true
        case "mixed_array": value = ["one", 2]
        case "object": value = ["nested": "one"]
        default: value = String(repeating: "a", count: 8_193)
        }
        let data = try CardCallbackFixture.data(values: ["followup": value])
        #expect(throws: CardCallbackFailure.malformed) {
            try CardCallback.decodeFromLongConnection(data, owner: CardCallbackFixture.owner, now: CardCallbackFixture.date)
        }
    }

    @Test func boundsTheEntireCallbackAndRejectsInvalidLocalTime() throws {
        let data = try CardCallbackFixture.data()
        #expect(throws: CardCallbackFailure.malformed) {
            try CardCallback.decodeFromLongConnection(Data(repeating: 32, count: 65_537),
                                                       owner: CardCallbackFixture.owner, now: CardCallbackFixture.date)
        }
        #expect(throws: CardCallbackFailure.malformed) {
            try CardCallback.decodeFromLongConnection(data, owner: CardCallbackFixture.owner,
                                                       now: Date(timeIntervalSince1970: .nan))
        }
    }
}
