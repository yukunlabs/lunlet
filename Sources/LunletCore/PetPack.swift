// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.01, AC-40.02, AC-40.03, AC-40.04, AC-40.07; US-39, AC-39.03; US-26, AC-26.02.
import Foundation

/// Where a pet pack was found. A Codex pack is read in place and never written (AC-40.02).
public enum PetPackSource: String, Codable, Sendable, CaseIterable {
    case lunlet, codex
    public var title: String { self == .lunlet ? "Lunlet" : "Codex" }
}

/// A pack's identity in preferences: its source and the folder it lives in, as `source/folder`.
public struct PetPackReference: Hashable, Codable, Sendable {
    public let source: PetPackSource
    public let folder: String
    public init(source: PetPackSource, folder: String) { self.source = source; self.folder = folder }
    public var key: String { source.rawValue + "/" + folder }
    public init?(key: String) {
        guard let slash = key.firstIndex(of: "/"), let source = PetPackSource(rawValue: String(key[..<slash])) else { return nil }
        let folder = String(key[key.index(after: slash)...])
        guard Self.isValidFolder(folder) else { return nil }
        self.init(source: source, folder: folder)
    }
    /// A folder name Lunlet lists: one path component, not hidden, at most 64 characters.
    public static func isValidFolder(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}

/// The manifest of a pack in Codex's format (`pet.json`).
public struct PetPackManifest: Decodable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let spriteVersionNumber: Int?
    public let spritesheetPath: String
    public init(id: String, displayName: String, description: String? = nil, spriteVersionNumber: Int? = nil, spritesheetPath: String) {
        self.id = id; self.displayName = displayName; self.description = description
        self.spriteVersionNumber = spriteVersionNumber; self.spritesheetPath = spritesheetPath
    }
}

/// The sheet layouts Lunlet reads: 8 columns of 192 × 208 cells, nine rows (v1) or eleven with the look rows (v2).
public enum PetSpriteVersion: Int, Equatable, Sendable {
    case v1 = 1, v2 = 2
    public var rows: Int { self == .v1 ? 9 : 11 }
    public var sheetWidth: Int { PetSpriteLayout.columns * PetSpriteLayout.cellWidth }
    public var sheetHeight: Int { rows * PetSpriteLayout.cellHeight }
    public var hasLookRows: Bool { self == .v2 }
}

public enum PetSpriteLayout {
    public static let columns = 8
    public static let cellWidth = 192
    public static let cellHeight = 208
    /// The two look rows of a v2 sheet: sixteen directions clockwise from up in 22.5° steps.
    public static let firstLookRow = 9
    public static let lookDirections = 16
}

/// The standard animation rows and the time each frame holds, from the format's contract (AC-40.04).
public enum PetSpriteRow: Int, CaseIterable, Equatable, Sendable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review
    public var durations: [TimeInterval] {
        func run(_ count: Int, _ each: Double, last: Double) -> [TimeInterval] {
            Array(repeating: each / 1000, count: count - 1) + [last / 1000]
        }
        switch self {
        case .idle: return [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .runningRight, .runningLeft: return run(8, 120, last: 220)
        case .waving: return run(4, 140, last: 280)
        case .jumping: return run(5, 140, last: 280)
        case .failed: return run(8, 140, last: 240)
        case .waiting: return run(6, 150, last: 260)
        case .running: return run(6, 120, last: 220)
        case .review: return run(6, 150, last: 280)
        }
    }
    public var frameCount: Int { durations.count }
    public var duration: TimeInterval { durations.reduce(0, +) }
}

/// Why a pack cannot be used; shown beside it in Settings (AC-40.02, AC-40.07).
public enum PetPackFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case manifestMissing
    case manifestUnreadable
    case missingField(String)
    case invalidSpritesheetPath
    case spritesheetMissing
    case unsupportedVersion(Int)
    case spritesheetUnreadable
    case wrongSheetSize(width: Int, height: Int, expectedHeight: Int)
    public var description: String {
        switch self {
        case .manifestMissing: "pet.json is missing"
        case .manifestUnreadable: "pet.json is not valid JSON"
        case .missingField(let field): "pet.json has no \(field)"
        case .invalidSpritesheetPath: "spritesheetPath must name a file inside the pack"
        case .spritesheetMissing: "the sprite sheet file is missing"
        case .unsupportedVersion(let version): "spriteVersionNumber \(version) is not supported (1 or 2)"
        case .spritesheetUnreadable: "the sprite sheet is not a readable image"
        case .wrongSheetSize(let width, let height, let expected): "the sprite sheet is \(width) × \(height), not 1536 × \(expected)"
        }
    }
}

/// A valid pack: its manifest, its layout version and where its sheet is.
public struct PetPack: Equatable, Sendable {
    public let reference: PetPackReference
    public let manifest: PetPackManifest
    public let version: PetSpriteVersion
    public let directory: URL
    public let spritesheet: URL
    public var displayName: String { manifest.displayName }
}

/// One folder Lunlet found: a usable pack or the reason it is not.
public struct PetPackEntry: Equatable, Sendable {
    public let reference: PetPackReference
    public let result: Result<PetPack, PetPackFailure>
    public init(reference: PetPackReference, result: Result<PetPack, PetPackFailure>) { self.reference = reference; self.result = result }
    public var pack: PetPack? { try? result.get() }
    public var failure: PetPackFailure? { if case .failure(let failure) = result { failure } else { nil } }
    /// The manifest's name when readable, else the folder's.
    public var displayName: String { pack?.displayName ?? reference.folder }
}

/// Reads packs in place (AC-40.02). The sheet's pixel size comes from the platform's image reader, so this module
/// stays free of image decoding.
public enum PetPackReader {
    public static let manifestLimit = 64 * 1024
    public static func read(reference: PetPackReference, directory: URL,
                            sheetSize: (URL) -> (width: Int, height: Int)?) -> Result<PetPack, PetPackFailure> {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .failure(.manifestMissing) }
        guard let data = try? Data(contentsOf: manifestURL), data.count <= manifestLimit else { return .failure(.manifestUnreadable) }
        let manifest: PetPackManifest
        do { manifest = try JSONDecoder().decode(PetPackManifest.self, from: data) } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.missingField(key.stringValue))
        } catch { return .failure(.manifestUnreadable) }
        guard !manifest.id.isEmpty else { return .failure(.missingField("id")) }
        guard !manifest.displayName.isEmpty else { return .failure(.missingField("displayName")) }
        let path = manifest.spritesheetPath
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else {
            return .failure(.invalidSpritesheetPath)
        }
        let version: PetSpriteVersion
        switch manifest.spriteVersionNumber {
        case nil, 1: version = .v1
        case 2: version = .v2
        case let other?: return .failure(.unsupportedVersion(other))
        }
        let sheet = directory.appendingPathComponent(path).standardizedFileURL
        guard sheet.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return .failure(.invalidSpritesheetPath) }
        guard FileManager.default.fileExists(atPath: sheet.path) else { return .failure(.spritesheetMissing) }
        guard let size = sheetSize(sheet) else { return .failure(.spritesheetUnreadable) }
        guard size.width == version.sheetWidth, size.height == version.sheetHeight else {
            return .failure(.wrongSheetSize(width: size.width, height: size.height, expectedHeight: version.sheetHeight))
        }
        return .success(PetPack(reference: reference, manifest: manifest, version: version, directory: directory, spritesheet: sheet))
    }
    /// Every folder with a `pet.json` under `directory`, sorted by folder name; a missing directory lists nothing.
    public static func scan(source: PetPackSource, directory: URL,
                            sheetSize: (URL) -> (width: Int, height: Int)?) -> [PetPackEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter(PetPackReference.isValidFolder).sorted().compactMap { name in
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("pet.json").path) else { return nil }
            let reference = PetPackReference(source: source, folder: name)
            return PetPackEntry(reference: reference, result: read(reference: reference, directory: folder, sheetSize: sheetSize))
        }
    }
}

// MARK: Which cell to show

/// A cell of the sheet by row and column.
public struct PetSpriteFrame: Equatable, Sendable {
    public let row: Int
    public let column: Int
    public init(row: Int, column: Int) { self.row = row; self.column = column }
}

public enum PetDragDirection: Equatable, Sendable { case left, right }

/// What the frame rule needs: the pose and when it began, a click's jump, a drag and where the pet looks.
public struct PetSpriteCue: Equatable, Sendable {
    public var pose: PetPose
    public var poseChangedAt: TimeInterval
    /// Reference-date seconds of the click that plays jumping once (AC-40.03).
    public var jumpedAt: TimeInterval?
    /// The drag in progress and when it started; running-left or running-right plays meanwhile.
    public var drag: PetDragDirection?
    public var dragStartedAt: TimeInterval
    /// A unit offset (x right, y down) toward what the pet looks at; nil or the deadzone shows idle.
    public var lookX: Double?
    public var lookY: Double?
    public var hasLookRows: Bool
    public init(pose: PetPose, poseChangedAt: TimeInterval, jumpedAt: TimeInterval? = nil, drag: PetDragDirection? = nil,
                dragStartedAt: TimeInterval = 0, lookX: Double? = nil, lookY: Double? = nil, hasLookRows: Bool = false) {
        self.pose = pose; self.poseChangedAt = poseChangedAt; self.jumpedAt = jumpedAt; self.drag = drag
        self.dragStartedAt = dragStartedAt; self.lookX = lookX; self.lookY = lookY; self.hasLookRows = hasLookRows
    }
}

/// Maps Lunlet's poses and moments onto a pack's rows (AC-40.03, AC-40.04).
public enum PetSpriteRule {
    /// The standard row behind a pose: Asleep and Idle use idle, Working running, Waiting waiting, Done review, Failed failed.
    public static func row(for pose: PetPose) -> PetSpriteRow {
        switch pose {
        case .asleep, .idle: .idle
        case .working: .running
        case .waiting: .waiting
        case .done: .review
        case .failed: .failed
        }
    }
    /// The look-direction index, 0 up and clockwise in 22.5° steps, or nil inside the deadzone.
    public static func lookIndex(x: Double, y: Double) -> Int? {
        guard (x * x + y * y).squareRoot() >= 0.12 else { return nil }
        var degrees = atan2(x, -y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return Int((degrees + 11.25) / 22.5) % PetSpriteLayout.lookDirections
    }
    public static func lookFrame(index: Int) -> PetSpriteFrame {
        PetSpriteFrame(row: PetSpriteLayout.firstLookRow + index / PetSpriteLayout.columns, column: index % PetSpriteLayout.columns)
    }
    /// The cell at `t`. Under Reduce Motion every row shows its first frame.
    public static func frame(at t: TimeInterval, cue: PetSpriteCue, reduceMotion: Bool = false) -> PetSpriteFrame {
        if let drag = cue.drag {
            let row: PetSpriteRow = drag == .left ? .runningLeft : .runningRight
            return PetSpriteFrame(row: row.rawValue, column: reduceMotion ? 0 : column(in: row, elapsed: t - cue.dragStartedAt, loop: true))
        }
        if let jumpedAt = cue.jumpedAt, t >= jumpedAt, t - jumpedAt < PetSpriteRow.jumping.duration {
            return PetSpriteFrame(row: PetSpriteRow.jumping.rawValue, column: reduceMotion ? 0 : column(in: .jumping, elapsed: t - jumpedAt, loop: false))
        }
        if cue.pose == .idle, cue.hasLookRows, let x = cue.lookX, let y = cue.lookY, let index = lookIndex(x: x, y: y) {
            return lookFrame(index: index)
        }
        let row = row(for: cue.pose)
        guard cue.pose != .asleep, !reduceMotion else { return PetSpriteFrame(row: row.rawValue, column: 0) }
        return PetSpriteFrame(row: row.rawValue, column: column(in: row, elapsed: t - cue.poseChangedAt, loop: true))
    }
    /// When the shown cell next changes after `t`, or nil while it stands still.
    public static func nextChange(after t: TimeInterval, cue: PetSpriteCue, reduceMotion: Bool = false) -> TimeInterval? {
        if let drag = cue.drag {
            guard !reduceMotion else { return nil }
            return boundary(in: drag == .left ? .runningLeft : .runningRight, after: t - cue.dragStartedAt, loop: true).map { $0 + cue.dragStartedAt }
        }
        if let jumpedAt = cue.jumpedAt, t >= jumpedAt, t - jumpedAt < PetSpriteRow.jumping.duration {
            // The frames of the jump, then the moment it ends and the pose's row returns.
            return reduceMotion ? jumpedAt + PetSpriteRow.jumping.duration
                : boundary(in: .jumping, after: t - jumpedAt, loop: false).map { $0 + jumpedAt } ?? jumpedAt + PetSpriteRow.jumping.duration
        }
        if cue.pose == .idle, cue.hasLookRows, let x = cue.lookX, let y = cue.lookY, lookIndex(x: x, y: y) != nil { return nil }
        guard cue.pose != .asleep, !reduceMotion else { return nil }
        return boundary(in: row(for: cue.pose), after: t - cue.poseChangedAt, loop: true).map { $0 + cue.poseChangedAt }
    }
    static func column(in row: PetSpriteRow, elapsed: TimeInterval, loop: Bool) -> Int {
        let durations = row.durations
        var remaining = loop ? elapsed.truncatingRemainder(dividingBy: row.duration) : elapsed
        if remaining < 0 { remaining += row.duration }
        for (index, hold) in durations.enumerated() {
            if remaining < hold { return index }
            remaining -= hold
        }
        return durations.count - 1
    }
    /// The next frame boundary after `elapsed` seconds into the row; nil after a one-shot row's last boundary.
    static func boundary(in row: PetSpriteRow, after elapsed: TimeInterval, loop: Bool) -> TimeInterval? {
        let total = row.duration
        let cycles = loop ? floor(elapsed / total) : 0
        var offset = elapsed - cycles * total
        if offset < 0 { offset += total; }
        var cumulative: TimeInterval = 0
        for hold in row.durations {
            cumulative += hold
            if cumulative > offset + 0.0005 { return cycles * total + cumulative }
        }
        return loop ? (cycles + 1) * total + row.durations[0] : nil
    }
}
