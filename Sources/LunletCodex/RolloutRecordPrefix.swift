// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.02, AC-04.03; US-02, AC-02.01, AC-02.05; US-25, AC-25.01.
import Foundation

/// What the first bytes of a rollout line show about its record, for a line too large to decode whole.
/// Codex writes the timestamp, the record's `type`, then `payload` with the payload's own `type` first, so both
/// names sit in the first bytes. A name the prefix does not show stays nil, and callers treat nil as possible.
struct RolloutRecordPrefix: Equatable, Sendable {
    /// Enough for the timestamp and both type names.
    static let length = 512
    let type: String?
    let payloadType: String?
    /// A message's `role`, which Codex writes before its content.
    let payloadRole: String?

    init(_ bytes: Data) {
        var scanner = PrefixScanner(bytes: Array(bytes.prefix(Self.length)))
        (type, payloadType, payloadRole) = scanner.record()
    }

    /// Whether the record could be one usage accounting reads: the session identity, the turn's model or a token count.
    var mayCarryUsage: Bool {
        switch type {
        case nil, "session_meta", "turn_context": true
        case "event_msg": payloadType == nil || payloadType == "token_count"
        default: false
        }
    }
}

/// Reads the leading members of one JSON object without decoding it; any doubt ends the scan.
private struct PrefixScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func record() -> (type: String?, payloadType: String?, payloadRole: String?) {
        var type: String?, payload: (type: String?, role: String?) = (nil, nil)
        guard eat("{") else { return (nil, nil, nil) }
        while let key = string(), eat(":") {
            if key == "type" {
                guard let value = string() else { break }
                type = value
            } else if key == "payload" {
                // The payload is the oversized part: only its leading members are within reach.
                payload = leadingNames()
                break
            } else if !skipValue() { break }
            guard eat(",") else { break }
        }
        return (type, payload.type, payload.role)
    }

    /// The payload's `type` and `role` among the members that end within the prefix.
    private mutating func leadingNames() -> (type: String?, role: String?) {
        var type: String?, role: String?
        guard eat("{") else { return (nil, nil) }
        while let key = string(), eat(":") {
            if key == "type" || key == "role" {
                guard let value = string() else { break }
                if key == "type" { type = value } else { role = value }
            } else if !skipValue() { break }
            guard eat(",") else { break }
        }
        return (type, role)
    }

    private mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
    }
    private mutating func eat(_ character: Unicode.Scalar) -> Bool {
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }
    /// A complete string's raw contents; a name with an escape never equals a known record type.
    private mutating func string() -> String? {
        guard eat("\"") else { return nil }
        let start = index
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") {
                defer { index += 1 }
                return String(decoding: bytes[start..<index], as: UTF8.self)
            }
            index += 1
        }
        return nil
    }
    /// Passes one complete value, or fails when the prefix ends inside it.
    private mutating func skipValue() -> Bool {
        skipSpace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case UInt8(ascii: "\""): return string() != nil
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard string() != nil else { return false }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                index += 1
                if depth == 0 { return true }
            }
            return false
        default:
            // A number or literal ends at the next separator.
            let start = index
            while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
            return index > start && index < bytes.count
        }
    }
}
