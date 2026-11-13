// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.02, AC-04.03; US-02, AC-02.01, AC-02.05.
import Foundation
import Testing
@testable import LunletCodex

/// A line too large to decode is judged by its first bytes; whatever they do not show stays unknown.
struct RolloutRecordPrefixTests {
    private func prefix(_ text: String) -> RolloutRecordPrefix { .init(Data(text.utf8)) }
    private let filler = String(repeating: "x", count: 4096)

    @Test func theRecordAndPayloadTypesAreReadInCodexOrder() {
        let tool = prefix(#"{"timestamp":"2026-10-26T12:00:00.123Z","type":"response_item","payload":{"type":"function_call_output","output":""# + filler)
        #expect(tool.type == "response_item" && tool.payloadType == "function_call_output" && !tool.mayCarryUsage)
        let spaced = prefix("{ \"timestamp\" : \"2026-10-26T12:00:00Z\",\n \"type\" : \"event_msg\", \"payload\" : { \"type\" : \"task_complete\", \"x\":\"" + filler)
        #expect(spaced.type == "event_msg" && spaced.payloadType == "task_complete" && !spaced.mayCarryUsage)
        // Members before the type are passed over whatever their kind.
        let extras = prefix(#"{"seq":12,"meta":{"a":[1,"}",{"b":null}]},"ok":true,"type":"compacted","payload":{"message":""# + filler)
        #expect(extras.type == "compacted" && extras.payloadType == nil && !extras.mayCarryUsage)
        let later = prefix(#"{"type":"event_msg","payload":{"id":"a\"b","turn":7,"type":"token_count","info":""# + filler)
        #expect(later.payloadType == "token_count" && later.mayCarryUsage)
        // A message names its role before its content.
        let image = prefix(#"{"timestamp":"2026-10-26T12:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":""# + filler)
        #expect(image.payloadType == "message" && image.payloadRole == "user" && tool.payloadRole == nil)
    }

    @Test func accountingRecordsAndAnythingUnreadableStayPossible() {
        for type in ["session_meta", "turn_context"] {
            #expect(prefix(#"{"timestamp":"2026-10-26T12:00:00Z","type":""# + type + #"","payload":{"x":""# + filler).mayCarryUsage)
        }
        // The payload's own type is beyond reach, so a token count cannot be ruled out.
        #expect(prefix(#"{"timestamp":"2026-10-26T12:00:00Z","type":"event_msg","payload":{"text":""# + filler).mayCarryUsage)
        // The payload comes first, text that is not an object, a type that is not a string, an empty line.
        for unreadable in [#"{"payload":{"output":""# + filler, filler, #"{"type":7,"payload":{"output":""# + filler, "",
                           #"{"timestamp":"2026-10-26T12:00:00Z","ty"#] {
            let value = prefix(unreadable)
            #expect(value.type == nil && value.mayCarryUsage)
        }
        // An escaped name is never taken for a known record type.
        #expect(prefix(#"{"type":"response_item","payload":{"type":"x","y":""# + filler).type == #"response_item"#)
    }

    @Test func onlyTheKeptPrefixIsRead() {
        let padding = String(repeating: " ", count: RolloutRecordPrefix.length)
        #expect(prefix("{" + padding + #""type":"response_item"}"#).type == nil)
    }
}
