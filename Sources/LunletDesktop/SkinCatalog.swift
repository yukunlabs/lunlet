// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-17, AC-17.01, AC-17.02, AC-17.03, AC-17.04, AC-17.05, AC-17.07, AC-17.08; US-26, AC-26.02.
import Combine
import Darwin
import Foundation

enum SkinKind: String, Codable, Sendable {
    case vine, lantern
    /// The color drawn when neither the skin nor the owner chose an accent: the vine's
    /// middle pearl tone or the lantern glass. The allowance gradient keeps its own default.
    var fallbackAccent: AllowanceColor { .init(hex: self == .lantern ? 0xc83f49 : 0xb7afe5) }
    var fallbackAccentHex: String { String(format: "#%06X", fallbackAccent.hex) }
    /// Controls need contrast on light and dark materials. The pale vine pearl does not provide
    /// it, so the default vine controls use a deeper shade; the lantern glass already contrasts.
    var fallbackControlTint: AllowanceColor { self == .lantern ? fallbackAccent : .init(hex: 0x856bc7) }
}
enum SkinFailure: Error { case invalidPackage, invalidPath, reservedID, storageUnavailable }

struct SkinDefinition: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: String
    var title: String
    var kind: SkinKind
    var accentHex: String?
    var strokeWidth = 2.6
    var leftWord: String?
    var rightWord: String?
    var bodyPath: String?
    var foliage = true

    init(id: String, title: String, kind: SkinKind) { self.id = id; self.title = title; self.kind = kind }
    /// Official catalog membership owns color editing; imported packages own their colors.
    var allowsColorEditing: Bool { SkinCatalog.builtins.contains { $0.id == id } }
    func resolvedAccent(override: String?) -> String? {
        return allowsColorEditing ? override ?? accentHex : accentHex
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, kind, accentHex, strokeWidth, leftWord, rightWord, bodyPath, foliage
    }
    init(from decoder: any Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try data.decode(Int.self, forKey: .schemaVersion)
        id = try data.decode(String.self, forKey: .id)
        title = try data.decode(String.self, forKey: .title)
        kind = try data.decode(SkinKind.self, forKey: .kind)
        accentHex = try data.decodeIfPresent(String.self, forKey: .accentHex)
        strokeWidth = try data.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2.6
        leftWord = try data.decodeIfPresent(String.self, forKey: .leftWord)
        rightWord = try data.decodeIfPresent(String.self, forKey: .rightWord)
        bodyPath = try data.decodeIfPresent(String.self, forKey: .bodyPath)
        foliage = try data.decodeIfPresent(Bool.self, forKey: .foliage) ?? true
        try validate()
    }
    func validate() throws {
        guard schemaVersion == 1, id.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
              !title.isEmpty, title.count <= 48, title.rangeOfCharacter(from: .controlCharacters) == nil,
              strokeWidth.isFinite, (0.75...5).contains(strokeWidth),
              accentHex.map({ AllowanceColor(hexString: $0) != nil }) ?? true else { throw SkinFailure.invalidPackage }
        let word = EntryMetrics.wordSize, body = EntryMetrics.artworkSize
        for source in [leftWord, rightWord].compactMap({ $0 }) {
            try SkinPathValidation.check(source, width: word.width, height: word.height)
        }
        if let bodyPath { try SkinPathValidation.check(bodyPath, width: body.width, height: body.height, continuous: true) }
    }
}

/// User paths use a deliberately small grammar. Validate complete token coverage,
/// arity, finite coordinates and drawing bounds before the native path builder.
private enum SkinPathValidation {
    static let tokens = try! NSRegularExpression(pattern: #"[MLCZ]|-?(?:[0-9]*\.)?[0-9]+"#)
    static func check(_ source: String, width: Double, height: Double, continuous: Bool = false) throws {
        guard !source.isEmpty, source.utf8.count <= 16_384 else { throw SkinFailure.invalidPath }
        let text = source as NSString, matches = tokens.matches(in: source, range: NSRange(location: 0, length: text.length))
        var end = 0
        for match in matches {
            let gap = text.substring(with: NSRange(location: end, length: match.range.location - end))
            guard gap.allSatisfy({ " ,\t\r\n".contains($0) }) else { throw SkinFailure.invalidPath }
            end = NSMaxRange(match.range)
        }
        guard text.substring(from: end).allSatisfy({ " ,\t\r\n".contains($0) }) else { throw SkinFailure.invalidPath }
        let values = matches.map { text.substring(with: $0.range) }
        guard values.first == "M", !continuous || values.filter({ $0 == "M" }).count == 1 else { throw SkinFailure.invalidPath }
        var cursor = 0, commands = 0, drawing = false
        while cursor < values.count {
            let command = values[cursor]; cursor += 1; commands += 1
            guard commands <= 256 else { throw SkinFailure.invalidPath }
            let count: Int
            switch command { case "M", "L": count = 2; case "C": count = 6; case "Z": count = 0; default: throw SkinFailure.invalidPath }
            guard cursor + count <= values.count else { throw SkinFailure.invalidPath }
            for index in 0..<count {
                guard let number = Double(values[cursor + index]), number.isFinite,
                      number >= 0, number <= (index.isMultiple(of: 2) ? width : height) else { throw SkinFailure.invalidPath }
            }
            cursor += count
            if command == "L" || command == "C" { drawing = true }
        }
        guard drawing else { throw SkinFailure.invalidPath }
    }
}

enum LanternLevels {
    static func values(remaining: Double?) -> [Double]? {
        guard let remaining = AllowancePalette.normalized(remaining) else { return nil }
        return (0..<5).map { min(1, max(0, remaining / 20 - Double($0))) }
    }
}

@MainActor final class SkinCatalog: ObservableObject {
    nonisolated static let builtins: [SkinDefinition] = [.init(id: "vine", title: "Vine", kind: .vine),
                                              .init(id: "lantern", title: "Red lanterns", kind: .lantern)]
    /// Installed custom skins, in addition to the built-ins.
    nonisolated static let customLimit = 64
    @Published private(set) var skins = builtins
    @Published private(set) var issue: String?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet/skins", isDirectory: true)
        reload()
    }
    func skin(id: String) -> SkinDefinition { Self.skin(id: id, in: skins) }
    nonisolated static func skin(id: String, in skins: [SkinDefinition]) -> SkinDefinition {
        skins.first { $0.id == id } ?? builtins[0]
    }
    /// The single accent resolution: the owner's color for official skins, otherwise the skin's own.
    /// Nil keeps every drawing's default, including the allowance gradient.
    func accentHex(for preferences: LunletPreferences) -> String? { Self.accentHex(for: preferences, in: skins) }
    nonisolated static func accentHex(for preferences: LunletPreferences, in skins: [SkinDefinition]) -> String? {
        skin(id: preferences.skinID, in: skins).resolvedAccent(override: preferences.accentHex)
    }
    /// The accent a control shows or tints with, which is always the color the artwork draws.
    func displayedAccentHex(for preferences: LunletPreferences) -> String {
        accentHex(for: preferences) ?? skin(id: preferences.skinID).kind.fallbackAccentHex
    }
    /// The panel control tint: a chosen accent when one exists, otherwise a contrast-safe default.
    func controlTint(for preferences: LunletPreferences) -> AllowanceColor {
        accentHex(for: preferences).flatMap(AllowanceColor.init(hexString:))
            ?? skin(id: preferences.skinID).kind.fallbackControlTint
    }

    @discardableResult func install(_ data: Data) throws -> SkinDefinition {
        let skin = try Self.decode(data)
        guard !Self.builtins.contains(where: { $0.id == skin.id }) else { throw SkinFailure.reservedID }
        guard skins.count < Self.builtins.count + Self.customLimit || skins.contains(where: { $0.id == skin.id }) else {
            throw SkinFailure.invalidPackage
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkinFailure.storageUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = directory.appendingPathComponent(skin.id + ".json")
        try encoder.encode(skin).write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        skins.removeAll { $0.id == skin.id }; skins.append(skin)
        issue = nil
        return skin
    }
    private func reload() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else {
            issue = "Custom skins could not be read. Built-in skins remain available."; return
        }
        let candidates = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in candidates.prefix(Self.customLimit) {
            let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { issue = "Some custom skins could not be read."; continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65_537), let skin = try? Self.decode(data),
                  !Self.builtins.contains(where: { $0.id == skin.id }), !skins.contains(where: { $0.id == skin.id }) else {
                issue = "Some custom skins were invalid. Built-in skins remain available."; continue
            }
            skins.append(skin)
        }
    }
    private static func decode(_ data: Data) throws -> SkinDefinition {
        let fields: Set<String> = ["schemaVersion", "id", "title", "kind", "accentHex", "strokeWidth", "leftWord", "rightWord", "bodyPath", "foliage"]
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: fields) else { throw SkinFailure.invalidPackage }
        return try JSONDecoder().decode(SkinDefinition.self, from: data)
    }
}
