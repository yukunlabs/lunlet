// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-10, AC-10.02, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04.
import Foundation
import Testing
import SwiftProtobuf
@testable import LunletFeishu

struct FrameAssemblerTests {
    private func frame(id: String = "message_synthetic", sequence: Int = 0, total: Int = 1,
                       payload: Data = Data("{}".utf8), type: String = "event") -> FeishuWireFrame {
        var frame = FeishuWireFrame()
        frame.seqID = 1; frame.logID = 2; frame.service = 42; frame.method = 1
        frame.headers = [("type", type), ("message_id", id), ("seq", String(sequence)), ("sum", String(total))].map { key, value in
            var header = FeishuWireHeader(); header.key = key; header.value = value; return header
        }
        frame.payload = payload
        return frame
    }

    private func event(_ result: FeishuFrameResult) throws -> FeishuFrameEvent {
        guard case .event(let event) = result else {
            Issue.record("Expected one complete provider event"); throw FeishuFrameFailure.invalidFrame
        }
        return event
    }

    @Test func decodesTheIndependentLiteralReferenceFrame() throws {
        // Field tags and lengths checked independently against the provider schema.
        let hex = "08011002182a20012a0d0a047479706512056576656e742a0f0a0a6d6573736167655f696412016d2a080a037365711201302a080a0373756d12013142027b7d"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let assembler = FrameAssembler(serviceID: 42)
        let value = try event(assembler.receive(Data(bytes), now: 0))
        #expect(value.payload == Data("{}".utf8))
        #expect(value.frame.seqID == 1 && value.frame.logID == 2)
        #expect(value.frame.headers.contains { $0.key == "message_id" && $0.value == "m" })
    }

    @Test func reassemblesOutOfOrderFragmentsBeforeDecodingSplitUTF8() throws {
        let payload = Data(#"{"answer":"café ✓"}"#.utf8)
        let split = payload.firstIndex(of: 0xC3)! + 1
        let first = frame(sequence: 0, total: 2, payload: Data(payload[..<split]))
        let second = frame(sequence: 1, total: 2, payload: Data(payload[split...]))
        let assembler = FrameAssembler(serviceID: 42)
        guard case .incomplete = try assembler.receive(second.serializedData(), now: 0) else { Issue.record("Wait for missing bytes"); return }
        guard case .incomplete = try assembler.receive(second.serializedData(), now: 1) else { Issue.record("Identical fragments cannot complete a message"); return }
        let value = try event(assembler.receive(first.serializedData(), now: 2))
        #expect(String(data: value.payload, encoding: .utf8) == #"{"answer":"café ✓"}"#)
    }

    @Test func acknowledgmentsPreserveFullWidthIdentityAndEncodeTheToastResponse() throws {
        var input = frame()
        input.seqID = UInt64.max; input.logID = UInt64.max - 1; input.logIDNew = "log_synthetic"
        let event = try event(FrameAssembler(serviceID: 42).receive(input.serializedData(), now: 0))
        let reply = Data(#"{"toast":{"type":"info","content":"Received"}}"#.utf8)
        let ack = try FeishuWireFrame(serializedBytes: FrameAssembler.acknowledgment(for: event, responseJSON: reply, elapsedMilliseconds: 7))
        #expect(ack.seqID == UInt64.max && ack.logID == UInt64.max - 1 && ack.logIDNew == "log_synthetic")
        #expect(ack.service == 42 && ack.method == 1)
        #expect(ack.headers.filter { $0.key == "biz_rt" }.map(\.value) == ["7"])
        let body = try JSONSerialization.jsonObject(with: ack.payload) as! [String: Any]
        #expect(body["code"] as? Int == 200)
        #expect(Data(base64Encoded: body["data"] as! String) == reply)
        let failed = try FeishuWireFrame(serializedBytes: FrameAssembler.acknowledgment(for: event, responseJSON: nil, elapsedMilliseconds: 2))
        let failure = try JSONSerialization.jsonObject(with: failed.payload) as! [String: Any]
        #expect(failure["code"] as? Int == 500 && failure["data"] == nil)
    }

    @Test func pingAndPongUseApplicationFramesAndNeverBecomeCardActions() throws {
        let ping = try FeishuWireFrame(serializedBytes: FrameAssembler.ping(serviceID: 42))
        #expect(ping.service == 42 && ping.method == 0 && ping.seqID == 0 && ping.logID == 0)
        #expect(ping.headers.map(\.key) == ["type"] && ping.headers.map(\.value) == ["ping"])
        var pong = frame(payload: Data(#"{"PingInterval":60}"#.utf8), type: "pong")
        pong.method = 0
        let result = try FrameAssembler(serviceID: 42).receive(pong.serializedData(), now: 0)
        guard case .pong(let data) = result else { Issue.record("A pong must remain a control frame"); return }
        #expect(data == Data(#"{"PingInterval":60}"#.utf8))
        let legacy = try FrameAssembler(serviceID: 42).receive(frame(type: "card").serializedData(), now: 0)
        guard case .ignored = legacy else { Issue.record("Legacy card frames are unsupported"); return }
    }

    @Test func conflictingFragmentsAndChangedAssemblyMetadataFailClosed() throws {
        for conflicting in [frame(sequence: 0, total: 2, payload: Data("different".utf8)),
                            frame(sequence: 1, total: 3)] {
            let assembler = FrameAssembler(serviceID: 42)
            _ = try assembler.receive(frame(sequence: 0, total: 2).serializedData(), now: 0)
            #expect(throws: FeishuFrameFailure.invalidFrame) { try assembler.receive(conflicting.serializedData(), now: 1) }
        }
    }

    @Test func expiredPartialMessagesCannotMixOldAndNewBytes() throws {
        let assembler = FrameAssembler(serviceID: 42)
        _ = try assembler.receive(frame(sequence: 0, total: 2, payload: Data("old".utf8)).serializedData(), now: 0)
        let second = frame(sequence: 1, total: 2, payload: Data("new".utf8))
        guard case .incomplete = try assembler.receive(second.serializedData(), now: 10) else { Issue.record("Expired bytes must be removed"); return }
    }

    @Test func invalidServicesRequiredFieldsAndAmbiguousHeadersCannotBeDecoded() throws {
        var wrongService = frame(); wrongService.service = 43
        var missing = frame(); missing.clearLogID()
        var duplicate = frame(); duplicate.headers.append(duplicate.headers[0])
        var negative = frame(sequence: -1, total: 2)
        negative.method = 1
        for data in [try wrongService.serializedData(), try missing.serializedData(partial: true),
                     try duplicate.serializedData(), try negative.serializedData(), Data([0x80]), Data(repeating: 32, count: 65_537)] {
            #expect(throws: FeishuFrameFailure.invalidFrame) { try FrameAssembler(serviceID: 42).receive(data, now: 0) }
        }
    }

    @Test func incompleteMessageCountAndTotalStorageAreBounded() throws {
        let assembler = FrameAssembler(serviceID: 42)
        for index in 0..<32 { _ = try assembler.receive(frame(id: "m_\(index)", total: 2).serializedData(), now: 0) }
        #expect(throws: FeishuFrameFailure.assemblyLimit) {
            try assembler.receive(frame(id: "overflow", total: 2).serializedData(), now: 0)
        }
        let bytes = FrameAssembler(serviceID: 42)
        for index in 0..<4 {
            _ = try bytes.receive(frame(id: "large_\(index)", total: 2, payload: Data(repeating: 32, count: 60_000)).serializedData(), now: 0)
        }
        #expect(throws: FeishuFrameFailure.assemblyLimit) {
            try bytes.receive(frame(id: "large_overflow", total: 2, payload: Data(repeating: 32, count: 60_000)).serializedData(), now: 0)
        }
    }
}
