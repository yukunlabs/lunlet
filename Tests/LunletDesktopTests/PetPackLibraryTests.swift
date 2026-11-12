// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.01, AC-40.02, AC-40.03, AC-40.05, AC-40.06, AC-40.07; US-26, AC-26.01, AC-26.02.
import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import LunletCore
@testable import LunletDesktop

@MainActor struct PetPackLibraryTests {
    /// A transparent PNG sheet with one opaque square in the first cell and a smaller one in the review row.
    static func sheet(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Pixel rows count from the top of the sheet; the context's origin is at the bottom.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 40, y: 60, width: 50, height: 30))
        context.fill(CGRect(x: 8 * 192 - 192 + 100, y: 8 * 208 + 20, width: 20, height: 20))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func pack(in root: URL, folder: String, version: Int?, width: Int = 1536, height: Int = 1872) throws {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let versionField = version.map { ",\"spriteVersionNumber\":\($0)" } ?? ""
        try Data("{\"id\":\"\(folder)\",\"displayName\":\"\(folder.capitalized)\"\(versionField),\"spritesheetPath\":\"spritesheet.png\"}".utf8)
            .write(to: directory.appendingPathComponent("pet.json"))
        try sheet(width: width, height: height).write(to: directory.appendingPathComponent("spritesheet.png"))
    }
    private func roots() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-petlib-" + UUID().uuidString, isDirectory: true)
        let lunlet = base.appendingPathComponent("lunlet", isDirectory: true), codex = base.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: lunlet, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return (lunlet, codex)
    }

    @Test func libraryListsBothFoldersReadsSheetSizesAndNamesEveryFault() throws {
        let (lunlet, codex) = try roots(); defer { try? FileManager.default.removeItem(at: lunlet.deletingLastPathComponent()) }
        try Self.pack(in: lunlet, folder: "mochi", version: nil)
        try Self.pack(in: codex, folder: "blob", version: 2, height: 2288)
        try Self.pack(in: codex, folder: "tiny", version: nil, width: 100, height: 100)
        let library = PetPackLibrary(lunletDirectory: lunlet, codexDirectory: codex)
        #expect(library.entries.map(\.reference.key) == ["lunlet/mochi", "codex/blob", "codex/tiny"])
        #expect(library.validEntries.map(\.displayName) == ["Mochi", "Blob"] && library.validEntries[1].pack?.version == .v2)
        #expect(library.invalidEntries.first?.failure == .wrongSheetSize(width: 100, height: 100, expectedHeight: 1872))
        #expect(PetPackLibrary.sheetSize(of: lunlet.appendingPathComponent("mochi/spritesheet.png")).map { $0.width == 1536 && $0.height == 1872 } == true)
        #expect(PetPackLibrary.sheetSize(of: lunlet.appendingPathComponent("mochi/pet.json")) == nil)
        try Self.pack(in: lunlet, folder: "later", version: nil)
        #expect(library.entry(for: PetPackReference(source: .lunlet, folder: "later")) == nil)
        library.refresh()
        #expect(library.entry(for: PetPackReference(source: .lunlet, folder: "later"))?.pack != nil)
    }

    @Test func sheetCellsMasksAndOpaqueBoundsFollowThePixels() async throws {
        let (lunlet, codex) = try roots(); defer { try? FileManager.default.removeItem(at: lunlet.deletingLastPathComponent()) }
        try Self.pack(in: lunlet, folder: "mochi", version: nil)
        let library = PetPackLibrary(lunletDirectory: lunlet, codexDirectory: codex)
        let pack = try #require(library.validEntries.first?.pack)
        let sheet = try #require(await library.loadSheet(for: pack))
        let first = PetSpriteFrame(row: 0, column: 0)
        #expect(sheet.cell(first)?.width == 192 && sheet.cell(first)?.height == 208)
        #expect(sheet.cell(PetSpriteFrame(row: 9, column: 0)) == nil && sheet.cell(PetSpriteFrame(row: 0, column: 8)) == nil)
        #expect(sheet.isOpaque(first, x: 45, y: 65) && sheet.isOpaque(first, x: 89, y: 89) && !sheet.isOpaque(first, x: 10, y: 10))
        #expect(!sheet.isOpaque(first, x: 45, y: 95) && !sheet.isOpaque(first, x: -1, y: 0))
        #expect(sheet.opaqueBounds(first) == CGRect(x: 40, y: 60, width: 50, height: 30))
        #expect(sheet.opaqueBounds(PetSpriteFrame(row: 0, column: 1)) == nil)
        #expect(sheet.opaqueBounds(PetSpriteFrame(row: 8, column: 7)) == CGRect(x: 100, y: 20, width: 20, height: 20))
        let top = PetSpriteDrawing.topCenter(in: PetEntryController.windowSize, sheet: sheet)
        let rect = PetSpriteDrawing.cellRect(in: PetEntryController.windowSize)
        #expect(abs(top.x - (rect.minX + 65 / 192 * rect.width)) < 0.01 && abs(top.y - (rect.minY + 60 / 208 * rect.height)) < 0.01)
    }

    @Test func aPackIsHitOnItsOpaquePixelsAndItsBubble() async throws {
        let (lunlet, codex) = try roots(); defer { try? FileManager.default.removeItem(at: lunlet.deletingLastPathComponent()) }
        try Self.pack(in: lunlet, folder: "mochi", version: nil)
        let library = PetPackLibrary(lunletDirectory: lunlet, codexDirectory: codex)
        let pack = try #require(library.validEntries.first?.pack)
        let sheet = try #require(await library.loadSheet(for: pack))
        let host = PetHostView(palette: PetPalette.make(coat: .golden, accent: AllowanceColor(hex: 0xC83F49)))
        host.frame = CGRect(origin: .zero, size: PetEntryController.windowSize)
        // Idle shows the first cell, the only one with pixels: the hit test follows the cell on show.
        let idle = PetState(pose: .idle, sessionID: nil, sessionCount: 1, waitingCount: 0, runningCount: 0, summary: nil)
        var input = PetMotionInput(); input.pose = .idle
        host.update(idle, appearance: .sprite(sheet), input: input, animating: false)
        let rect = PetSpriteDrawing.cellRect(in: host.bounds.size)
        func viewPoint(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 192 * rect.width, y: host.bounds.height - (rect.minY + y / 208 * rect.height))
        }
        #expect(host.isOnDog(viewPoint(x: 60, y: 75)) && !host.isOnDog(viewPoint(x: 150, y: 180)) && !host.isOnDog(CGPoint(x: 2, y: 2)))
        let state = PetState(pose: .waiting, sessionID: nil, sessionCount: 1, waitingCount: 1, runningCount: 0, summary: nil)
        input.pose = .waiting
        host.update(state, appearance: .sprite(sheet), input: input, animating: false)
        #expect(!host.isOnDog(viewPoint(x: 60, y: 75)))
        let bubble = PetSpriteDrawing.bubbleRect(in: host.bounds.size, sheet: sheet)
        let inBubble = CGPoint(x: bubble.midX, y: host.bounds.height - bubble.midY)
        #expect(host.isOnDog(inBubble))
        input.panelOpen = true
        host.update(state, appearance: .sprite(sheet), input: input, animating: false)
        #expect(!host.isOnDog(inBubble))
        #expect(host.headFrame.maxY == host.bounds.height - PetSpriteDrawing.topCenter(in: host.bounds.size, sheet: sheet).y)
    }

    @Test func theChosenPackShowsAndTheDogReturnsWithAReasonWhenItIsGone() async throws {
        let (lunlet, codex) = try roots(); defer { try? FileManager.default.removeItem(at: lunlet.deletingLastPathComponent()) }
        try Self.pack(in: lunlet, folder: "mochi", version: nil)
        let library = PetPackLibrary(lunletDirectory: lunlet, codexDirectory: codex)
        let defaults = try #require(UserDefaults(suiteName: "lunlet-pet-" + UUID().uuidString))
        let preferences = PreferencesStore(defaults: defaults)
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: NoCues())
        let entry = PetEntryController(companion: companion, sessions: sessions, preferences: preferences, packs: library,
                                       display: { nil }, available: { false }, motionAllowed: { false })
        defer { entry.shutdown() }
        preferences.update { $0.presentation = .pet; $0.petPack = "lunlet/mochi" }
        let deadline = ContinuousClock.now + .seconds(5)
        while entry.shownPack == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entry.shownPack == PetPackReference(source: .lunlet, folder: "mochi") && library.chosenProblem == nil)
        preferences.update { $0.petPack = "lunlet/absent" }
        #expect(entry.shownPack == nil && library.chosenProblem?.contains("absent") == true && library.chosenProblem?.contains("not found") == true)
        try Self.pack(in: codex, folder: "tiny", version: nil, width: 10, height: 10)
        library.refresh()
        preferences.update { $0.petPack = "codex/tiny" }
        #expect(entry.shownPack == nil && library.chosenProblem?.contains("invalid") == true)
        preferences.update { $0.petPack = nil }
        #expect(library.chosenProblem == nil)
    }
    private final class NoCues: TaskCuePresenting {
        func show(_ cues: [TaskCue]) {}
        func hide() {}
    }

    @Test func thePetPackPreferenceRoundTripsAndRejectsABadKey() throws {
        var value = LunletPreferences()
        #expect(value.petPack == nil)
        value.petPack = "codex/blob"
        let decoded = try JSONDecoder().decode(LunletPreferences.self, from: try JSONEncoder().encode(value))
        #expect(decoded == value)
        try value.validate()
        value.petPack = "nope/blob"
        #expect(throws: PreferenceFailure.invalidValue) { try value.validate() }
        value.petPack = "codex/../x"
        #expect(throws: PreferenceFailure.invalidValue) { try value.validate() }
    }

    @Test func theGalleryLinkOpensPetdexAndTheHelpNamesCodexsFolder() throws {
        // AC-40.01: Find pets on Petdex opens the gallery; packs installed with petdex install arrive through Codex's folder.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-pets-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PetPackLibrary(lunletDirectory: root.appendingPathComponent("lunlet"), codexDirectory: root.appendingPathComponent("codex"))
        #expect(PetPackLibrary.galleryURL.absoluteString == "https://petdex.dev")
        var opened: URL?
        library.openGallery { opened = $0 }
        #expect(opened == PetPackLibrary.galleryURL)
        #expect(PetPackLibrary.pickerHelp.contains("petdex install") && PetPackLibrary.pickerHelp.contains("Codex"))
    }
}
