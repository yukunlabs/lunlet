// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08.
import Foundation

/// Claude Code's settings as a strict JSON object, edited in place: only the bytes of one top-level member change,
/// so every other key keeps its order, spacing and spelling. Anything that is not a valid object is refused.
struct ClaudeSettingsDocument {
    enum Failure: Error, Equatable { case invalidJSON, notAnObject, duplicateKey }
    private struct Member { let key: String; let start: Int; let value: Range<Int> }

    let bytes: [UInt8]
    let object: [String: Any]
    private let members: [Member]
    private let open: Int, close: Int

    init(_ data: Data) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { throw Failure.invalidJSON }
        guard let object = parsed as? [String: Any] else { throw Failure.notAnObject }
        bytes = [UInt8](data); self.object = object
        var scanner = Scanner(bytes: bytes)
        (open, members, close) = try scanner.topLevelMembers()
        guard Set(members.map(\.key)).count == object.count else { throw Failure.invalidJSON }
    }

    /// The exact source text of a member's value; a key that appears twice is refused rather than guessed.
    func valueText(_ key: String) throws -> String? {
        let matches = members.filter { $0.key == key }
        guard matches.count <= 1 else { throw Failure.duplicateKey }
        return matches.first.map { String(decoding: bytes[$0.value], as: UTF8.self) }
    }

    /// Replaces a member's value text, or appends the member in the document's own style.
    func setting(_ key: String, to text: String) throws -> Data {
        _ = try valueText(key)
        let value = Array(text.utf8)
        if let member = members.first(where: { $0.key == key }) {
            return Data(bytes[..<member.value.lowerBound] + value + bytes[member.value.upperBound...])
        }
        let name = Array(try Self.literal(key).utf8)
        guard let last = members.last else {
            let interior = Array("\n  ".utf8) + name + Array(": ".utf8) + value + [0x0A]
            return Data(bytes[...open] + interior + bytes[close...])
        }
        let separator = Array(",".utf8) + (style.indent.map { [0x0A] + Array($0.utf8) } ?? [])
        let inserted = separator + name + style.colon + value
        return Data(bytes[..<last.value.upperBound] + inserted + bytes[last.value.upperBound...])
    }

    /// Removes a member and the separator it introduced; other bytes are unchanged.
    func removing(_ key: String) throws -> Data {
        _ = try valueText(key)
        guard let index = members.firstIndex(where: { $0.key == key }) else { return Data(bytes) }
        let member = members[index]
        let range: Range<Int>
        if index > 0 { range = members[index - 1].value.upperBound..<member.value.upperBound }
        else if members.count > 1 { range = member.start..<members[1].start }
        else { range = (open + 1)..<close }
        return Data(bytes[..<range.lowerBound] + bytes[range.upperBound...])
    }

    /// Indentation of the first member, nil for a single-line document, and the key-value separator it uses.
    var style: (indent: String?, colon: [UInt8]) {
        guard let first = members.first else { return ("  ", Array(": ".utf8)) }
        let keyEnd = Scanner.stringEnd(bytes, from: first.start) ?? first.start
        let colon = Array(bytes[keyEnd..<first.value.lowerBound])
        let lead = bytes[(open + 1)..<first.start]
        guard let newline = lead.lastIndex(of: 0x0A) else { return (nil, colon) }
        return (String(decoding: bytes[(newline + 1)..<first.start], as: UTF8.self), colon)
    }

    /// A JSON string literal without escaped slashes, as Claude Code writes paths.
    static func literal(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A byte scanner over an already validated document; it records only top-level member positions.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func topLevelMembers() throws -> (Int, [Member], Int) {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
            skipSpace()
            guard index < bytes.count, bytes[index] == 0x7B else { throw Failure.notAnObject }
            let open = index
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == 0x7D { return (open, [], index) }
            while index < bytes.count {
                skipSpace()
                let start = index
                guard let end = Self.stringEnd(bytes, from: start),
                      let key = try? JSONSerialization.jsonObject(with: Data(bytes[start..<end]), options: .fragmentsAllowed)
                        as? String else { throw Failure.invalidJSON }
                index = end; skipSpace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw Failure.invalidJSON }
                index += 1; skipSpace()
                let valueStart = index
                try skipValue()
                members.append(.init(key: key, start: start, value: valueStart..<index))
                skipSpace()
                guard index < bytes.count else { break }
                if bytes[index] == 0x2C { index += 1; continue }
                if bytes[index] == 0x7D { return (open, members, index) }
                break
            }
            throw Failure.invalidJSON
        }

        /// The index after a string literal starting at `start`.
        static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int? {
            guard start < bytes.count, bytes[start] == 0x22 else { return nil }
            var cursor = start + 1
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 0x5C: cursor += 2
                case 0x22: return cursor + 1
                default: cursor += 1
                }
            }
            return nil
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func skipValue() throws {
            guard index < bytes.count else { throw Failure.invalidJSON }
            switch bytes[index] {
            case 0x22:
                guard let end = Self.stringEnd(bytes, from: index) else { throw Failure.invalidJSON }
                index = end
            case 0x7B, 0x5B:
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case 0x22:
                        guard let end = Self.stringEnd(bytes, from: index) else { throw Failure.invalidJSON }
                        index = end; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { index += 1; return }
                    default: break
                    }
                    index += 1
                }
                throw Failure.invalidJSON
            default:
                let start = index
                while index < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                guard index > start else { throw Failure.invalidJSON }
            }
        }
    }
}
