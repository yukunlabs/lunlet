// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-10, AC-10.02, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04.
import Foundation
import SwiftProtobuf

enum FeishuFrameFailure: Error, Equatable { case invalidFrame, assemblyLimit }

struct FeishuFrameEvent: Sendable, CustomStringConvertible {
    let payload: Data
    let frame: FeishuWireFrame
    var description: String { "Feishu frame event (redacted)" }
}

enum FeishuFrameResult: Sendable {
    case incomplete, ignored, pong(Data), event(FeishuFrameEvent)
}

/// Confine to one connection's receive loop; discard it on disconnect.
final class FrameAssembler {
    private struct Partial {
        let total: Int
        let startedAt: TimeInterval
        var pieces: [Int: Data] = [:]
        var byteCount = 0
    }
    private let serviceID: Int32
    private var partials: [String: Partial] = [:]
    private var previousTime: TimeInterval = 0

    init(serviceID: Int32) { self.serviceID = serviceID }

    func receive(_ data: Data, now: TimeInterval) throws -> FeishuFrameResult {
        guard serviceID > 0, now.isFinite, now >= previousTime,
              !data.isEmpty, data.count <= 65_536,
              let frame = try? FeishuWireFrame(serializedBytes: data), frame.service == serviceID,
              frame.headers.count <= 64 else { throw FeishuFrameFailure.invalidFrame }
        previousTime = now
        partials = partials.filter { now - $0.value.startedAt < 10 }
        var headers: [String: String] = [:]
        for header in frame.headers {
            guard !header.key.isEmpty, header.key.utf8.count <= 128, header.value.utf8.count <= 1_024,
                  headers.updateValue(header.value, forKey: header.key) == nil else { throw FeishuFrameFailure.invalidFrame }
        }
        guard let type = headers["type"] else { throw FeishuFrameFailure.invalidFrame }
        if frame.method == 0 { return type == "pong" ? .pong(frame.payload) : .ignored }
        guard frame.method == 1 else { throw FeishuFrameFailure.invalidFrame }
        guard type == "event" else { return .ignored }
        guard let id = headers["message_id"], !id.isEmpty, id.utf8.count <= 256,
              let total = Self.integer(headers["sum"]), total > 0, total <= 32,
              let sequence = Self.integer(headers["seq"]), sequence < total,
              frame.hasPayload else { throw FeishuFrameFailure.invalidFrame }
        if total == 1 {
            guard partials[id] == nil else { throw FeishuFrameFailure.invalidFrame }
            return .event(FeishuFrameEvent(payload: frame.payload, frame: frame))
        }
        var pending = partials[id] ?? Partial(total: total, startedAt: now)
        guard pending.total == total else { throw FeishuFrameFailure.invalidFrame }
        if let prior = pending.pieces[sequence] {
            guard prior == frame.payload else { throw FeishuFrameFailure.invalidFrame }
            return .incomplete
        }
        guard pending.byteCount + frame.payload.count <= 65_536 else { throw FeishuFrameFailure.assemblyLimit }
        if pending.pieces.count + 1 == total {
            partials.removeValue(forKey: id)
            pending.pieces[sequence] = frame.payload
            var payload = Data()
            for index in 0..<total {
                guard let part = pending.pieces[index] else { throw FeishuFrameFailure.invalidFrame }
                payload.append(part)
            }
            return .event(FeishuFrameEvent(payload: payload, frame: frame))
        }
        let storedBytes = partials.values.reduce(0) { $0 + $1.byteCount }
        guard (partials[id] != nil || partials.count < 32), storedBytes + frame.payload.count <= 262_144 else {
            throw FeishuFrameFailure.assemblyLimit
        }
        pending.pieces[sequence] = frame.payload
        pending.byteCount += frame.payload.count
        partials[id] = pending
        return .incomplete
    }

    static func ping(serviceID: Int32) throws -> Data {
        guard serviceID > 0 else { throw FeishuFrameFailure.invalidFrame }
        var frame = FeishuWireFrame()
        frame.seqID = 0; frame.logID = 0; frame.service = serviceID; frame.method = 0
        frame.headers = [header("type", "ping")]
        return try frame.serializedData()
    }

    static func acknowledgment(for event: FeishuFrameEvent, responseJSON: Data?, elapsedMilliseconds: Int) throws -> Data {
        guard elapsedMilliseconds >= 0, elapsedMilliseconds <= 60_000 else { throw FeishuFrameFailure.invalidFrame }
        var body: [String: Any] = ["code": responseJSON == nil ? 500 : 200]
        if let responseJSON {
            guard responseJSON.count <= 16_384,
                  (try? JSONSerialization.jsonObject(with: responseJSON)) is [String: Any] else {
                throw FeishuFrameFailure.invalidFrame
            }
            body["data"] = responseJSON.base64EncodedString()
        }
        var frame = event.frame
        frame.payload = try JSONSerialization.data(withJSONObject: body)
        frame.headers.removeAll { $0.key == "biz_rt" }
        frame.headers.append(header("biz_rt", String(elapsedMilliseconds)))
        let data = try frame.serializedData()
        guard data.count <= 65_536 else { throw FeishuFrameFailure.invalidFrame }
        return data
    }

    private static func header(_ key: String, _ value: String) -> FeishuWireHeader {
        var header = FeishuWireHeader(); header.key = key; header.value = value; return header
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.utf8.count <= 10,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }
}
