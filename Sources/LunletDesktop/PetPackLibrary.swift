// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.01, AC-40.02, AC-40.07; US-26, AC-26.02.
import AppKit
import ImageIO
import LunletCore
import SwiftUI

/// A decoded image handed from the decoding task to the main actor; it is never mutated.
struct DecodedImage: @unchecked Sendable { let image: CGImage }

/// The pet packs on this Mac: Lunlet's own pets folder and Codex's, read in place (AC-40.01, AC-40.02).
@MainActor final class PetPackLibrary: ObservableObject {
    @Published private(set) var entries: [PetPackEntry] = []
    /// Why the chosen pack is not the pet right now, for Settings (AC-40.07); nil while it is or none is chosen.
    @Published var chosenProblem: String?
    let lunletDirectory: URL
    let codexDirectory: URL

    init(lunletDirectory: URL? = nil, codexDirectory: URL? = nil) {
        self.lunletDirectory = lunletDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet/pets", isDirectory: true)
        self.codexDirectory = codexDirectory ?? Self.codexHome.appendingPathComponent("pets", isDirectory: true)
        refresh()
    }
    /// `${CODEX_HOME:-$HOME/.codex}`, as Codex resolves it.
    nonisolated static var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    func refresh() {
        entries = PetPackReader.scan(source: .lunlet, directory: lunletDirectory, sheetSize: Self.sheetSize)
            + PetPackReader.scan(source: .codex, directory: codexDirectory, sheetSize: Self.sheetSize)
    }
    func entry(for reference: PetPackReference) -> PetPackEntry? { entries.first { $0.reference == reference } }
    var validEntries: [PetPackEntry] { entries.filter { $0.pack != nil } }
    var invalidEntries: [PetPackEntry] { entries.filter { $0.failure != nil } }
    /// Creates Lunlet's pets folder when needed and shows it in the Finder, so a pack can be dropped in.
    func openLunletFolder() {
        try? FileManager.default.createDirectory(at: lunletDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(lunletDirectory)
    }
    /// The pixel size from the image header, without decoding the pixels.
    nonisolated static func sheetSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
    /// Decodes a pack's sheet off the main thread; nil when the file cannot be decoded.
    func loadSheet(for pack: PetPack) async -> PetSpriteSheet? {
        let url = pack.spritesheet
        guard let decoded = await Task.detached(priority: .utility) { Self.decode(url) }.value else { return nil }
        return PetSpriteSheet(pack: pack, image: decoded.image)
    }
    nonisolated static func decode(_ url: URL) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { return nil }
        return DecodedImage(image: image)
    }
}

private struct PetPackLibraryKey: EnvironmentKey { static let defaultValue: PetPackLibrary? = nil }
extension EnvironmentValues {
    var petPacks: PetPackLibrary? {
        get { self[PetPackLibraryKey.self] }
        set { self[PetPackLibraryKey.self] = newValue }
    }
}
