// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.01, AC-40.02, AC-40.07; US-26, AC-26.02; US-25, AC-25.01.
import AppKit
import ImageIO
import LunletCore
import SwiftUI

/// A decoded image handed from the decoding task to the main actor; it is never mutated.
struct DecodedImage: @unchecked Sendable { let image: CGImage }

/// The pet packs on this Mac: Lunlet's own pets folder and Codex's, read in place (AC-40.01, AC-40.02).
///
/// The app's library is deferred: creating it reads nothing, a chosen pack is read alone for the pet, and the folders
/// are listed away from the main actor when the picker first needs them (US-25). A library made for explicit folders
/// lists them at once, as tests and renders expect.
@MainActor final class PetPackLibrary: ObservableObject {
    @Published private(set) var entries: [PetPackEntry] = []
    /// Why the chosen pack is not the pet right now, for Settings (AC-40.07); nil while it is or none is chosen.
    @Published var chosenProblem: String?
    /// A folder held more packs than are read from one folder; the listing stops there.
    @Published private(set) var truncated = false
    let lunletDirectory: URL
    let codexDirectory: URL
    /// The Petdex gallery; `petdex install` writes every pet into Codex's folder as well, so it is listed from there (AC-40.01).
    static let galleryURL = URL(string: "https://petdex.dev")!
    static let pickerHelp = "Packs use Codex's pet format: a pet.json beside a sprite sheet. Packs in ~/.codex/pets are listed too "
        + "and only read; a pet installed with petdex install appears there as well."
    /// Packs read from one folder. A gallery install can leave hundreds of pets in Codex's folder; the listing is
    /// bounded, and a chosen pack beyond the bound is still read by name.
    nonisolated static let defaultLimit = 500

    private let deferred: Bool
    private let limit: Int
    /// What the picker says while a folder's listing stopped at the bound.
    var truncationNote: String? { truncated ? "Showing the first \(limit) packs of each folder." : nil }
    /// Whether the folders have been listed at least once.
    private(set) var hasScanned = false
    private var listing: Task<Void, Never>?
    /// Packs read by name while the folders were not listed, or beyond the cap; shown with the listed ones.
    private var named: [PetPackEntry] = []

    init(lunletDirectory: URL? = nil, codexDirectory: URL? = nil, deferred: Bool = false, limit: Int = PetPackLibrary.defaultLimit) {
        self.lunletDirectory = lunletDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet/pets", isDirectory: true)
        self.codexDirectory = codexDirectory ?? Self.codexHome.appendingPathComponent("pets", isDirectory: true)
        self.deferred = deferred; self.limit = max(1, limit)
        if !deferred { refresh() }
    }
    /// `${CODEX_HOME:-$HOME/.codex}`, as Codex resolves it.
    nonisolated static var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Lists both folders again: at once for a library of explicit folders, away from the main actor for the app's.
    func refresh() {
        guard deferred else {
            apply(Self.list(lunlet: lunletDirectory, codex: codexDirectory, limit: limit))
            return
        }
        listing?.cancel()
        let lunlet = lunletDirectory, codex = codexDirectory, limit = limit
        listing = Task { [weak self] in
            let listed = await Task.detached(priority: .utility) { Self.list(lunlet: lunlet, codex: codex, limit: limit) }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(listed); self.listing = nil
        }
    }
    /// Starts the first listing of a deferred library; later readers find it running or done.
    private func listIfNeeded() {
        guard deferred, !hasScanned, listing == nil else { return }
        refresh()
    }
    /// Waits for a listing in flight.
    func settle() async {
        var waited: Task<Void, Never>?
        while let task = listing, task != waited { waited = task; await task.value }
    }
    private func apply(_ listed: (entries: [PetPackEntry], truncated: Bool)) {
        hasScanned = true; named = []
        truncated = listed.truncated; entries = listed.entries
    }

    /// The pack a reference names. One the listing does not hold, because the folders are not listed yet or the
    /// listing stopped at its cap, is read alone by name; in a complete listing a missing pack is missing.
    func entry(for reference: PetPackReference) -> PetPackEntry? {
        if let listed = entries.first(where: { $0.reference == reference }) { return listed }
        if let known = named.first(where: { $0.reference == reference }) { return known }
        guard !hasScanned || truncated,
              let read = Self.read(reference, in: reference.source == .lunlet ? lunletDirectory : codexDirectory) else { return nil }
        named.append(read)
        return read
    }
    /// Everything known: the listed packs, then any read by name that the listing does not hold.
    private var known: [PetPackEntry] {
        listIfNeeded()
        return entries + named.filter { extra in !entries.contains { $0.reference == extra.reference } }
    }
    var validEntries: [PetPackEntry] { known.filter { $0.pack != nil } }
    var invalidEntries: [PetPackEntry] { known.filter { $0.failure != nil } }
    /// Opens the Petdex gallery in the browser (AC-40.01).
    func openGallery(with open: (URL) -> Void = { NSWorkspace.shared.open($0) }) { open(Self.galleryURL) }
    /// Creates Lunlet's pets folder when needed and shows it in the Finder, so a pack can be dropped in.
    func openLunletFolder() {
        try? FileManager.default.createDirectory(at: lunletDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(lunletDirectory)
    }

    /// Both folders, Lunlet's first, each sorted by folder name and read up to `limit` packs.
    nonisolated static func list(lunlet: URL, codex: URL, limit: Int) -> (entries: [PetPackEntry], truncated: Bool) {
        let own = list(source: .lunlet, directory: lunlet, limit: limit), shared = list(source: .codex, directory: codex, limit: limit)
        return (own.entries + shared.entries, own.truncated || shared.truncated)
    }
    /// Every folder with a `pet.json` under `directory`, sorted by folder name, as `PetPackReader.scan` lists them,
    /// stopping after `limit` packs; a missing directory lists nothing.
    nonisolated static func list(source: PetPackSource, directory: URL, limit: Int) -> (entries: [PetPackEntry], truncated: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], false) }
        var entries: [PetPackEntry] = []
        for name in names.filter(PetPackReference.isValidFolder).sorted() {
            guard holdsPack(directory.appendingPathComponent(name, isDirectory: true)) else { continue }
            if entries.count == limit { return (entries, true) }
            let reference = PetPackReference(source: source, folder: name)
            entries.append(.init(reference: reference, result: PetPackReader.read(
                reference: reference, directory: directory.appendingPathComponent(name, isDirectory: true), sheetSize: sheetSize)))
        }
        return (entries, false)
    }
    /// One pack by name; nil when its folder holds no pack.
    nonisolated static func read(_ reference: PetPackReference, in directory: URL) -> PetPackEntry? {
        let folder = directory.appendingPathComponent(reference.folder, isDirectory: true)
        guard PetPackReference.isValidFolder(reference.folder), holdsPack(folder) else { return nil }
        return .init(reference: reference, result: PetPackReader.read(reference: reference, directory: folder, sheetSize: sheetSize))
    }
    private nonisolated static func holdsPack(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("pet.json").path)
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
