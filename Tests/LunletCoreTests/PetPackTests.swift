// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.01, AC-40.02, AC-40.03, AC-40.04, AC-40.07.
import Foundation
import Testing
@testable import LunletCore

private extension Result where Success == PetPack, Failure == PetPackFailure {
    var fault: PetPackFailure? { if case .failure(let failure) = self { failure } else { nil } }
}
/// A read's result, handed over from the thread it ran on.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<PetPack, PetPackFailure>?
    var value: Result<PetPack, PetPackFailure>? { lock.withLock { stored } }
    func set(_ value: Result<PetPack, PetPackFailure>) { lock.withLock { stored = value } }
}
/// This process's physical footprint: now, and the highest the kernel has recorded for it.
private enum Footprint {
    private static func info() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return info
    }
    static func current() -> UInt64 { info().phys_footprint }
    static func lifetimePeak() -> UInt64 { UInt64(max(0, info().ledger_phys_footprint_peak)) }
}

struct PetPackTests {
    private func makePack(in root: URL, folder: String, manifest: String?, sheet: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json")) }
        if sheet { try Data([0x52, 0x49, 0x46, 0x46]).write(to: directory.appendingPathComponent("spritesheet.webp")) }
        return directory
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-pets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private let v1 = #"{"id":"blob","displayName":"Blob","description":"A blob.","spritesheetPath":"spritesheet.webp"}"#
    private let v2 = #"{"id":"blob","displayName":"Blob","spriteVersionNumber":2,"spritesheetPath":"spritesheet.webp"}"#

    @Test func packsAreReadInPlaceWithTheirVersionAndEveryFaultIsNamed() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let reference = PetPackReference(source: .codex, folder: "blob")
        func read(_ directory: URL, size: (width: Int, height: Int)?) -> Result<PetPack, PetPackFailure> {
            PetPackReader.read(reference: reference, directory: directory, sheetSize: { _ in size })
        }
        let one = try makePack(in: root, folder: "one", manifest: v1)
        let pack = try read(one, size: (1536, 1872)).get()
        #expect(pack.version == .v1 && pack.displayName == "Blob" && pack.spritesheet.lastPathComponent == "spritesheet.webp")
        #expect(pack.spritesheet.deletingLastPathComponent().standardizedFileURL == one.standardizedFileURL)
        let two = try makePack(in: root, folder: "two", manifest: v2)
        #expect(try read(two, size: (1536, 2288)).get().version == .v2)
        #expect(read(two, size: (1536, 1872)).fault == .wrongSheetSize(width: 1536, height: 1872, expectedHeight: 2288))
        #expect(read(one, size: (1536, 2288)).fault == .wrongSheetSize(width: 1536, height: 2288, expectedHeight: 1872))
        #expect(read(one, size: nil).fault == .spritesheetUnreadable)
        #expect(read(try makePack(in: root, folder: "three", manifest: #"{"id":"x","displayName":"X","spriteVersionNumber":3,"spritesheetPath":"s.webp"}"#), size: (1, 1)).fault == .unsupportedVersion(3))
        #expect(read(try makePack(in: root, folder: "four", manifest: #"{"id":"x","spritesheetPath":"s.webp"}"#), size: nil).fault == .missingField("displayName"))
        #expect(read(try makePack(in: root, folder: "five", manifest: "{not json"), size: nil).fault == .manifestUnreadable)
        #expect(read(try makePack(in: root, folder: "six", manifest: nil), size: nil).fault == .manifestMissing)
        #expect(read(try makePack(in: root, folder: "seven", manifest: v1, sheet: false), size: nil).fault == .spritesheetMissing)
        #expect(read(try makePack(in: root, folder: "eight", manifest: #"{"id":"x","displayName":"X","spritesheetPath":"../one/spritesheet.webp"}"#), size: (1536, 1872)).fault == .invalidSpritesheetPath)
        #expect(read(try makePack(in: root, folder: "nine", manifest: #"{"id":"","displayName":"X","spritesheetPath":"s.webp"}"#), size: nil).fault == .missingField("id"))
    }

    @Test func scanningListsEveryFolderWithAManifestAndSkipsTheRest() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePack(in: root, folder: "zed", manifest: v1)
        _ = try makePack(in: root, folder: "alpha", manifest: "{")
        _ = try makePack(in: root, folder: "no-manifest", manifest: nil)
        _ = try makePack(in: root, folder: ".hidden", manifest: v1)
        try Data().write(to: root.appendingPathComponent("stray-file"))
        let entries = PetPackReader.scan(source: .lunlet, directory: root, sheetSize: { _ in (1536, 1872) })
        #expect(entries.map(\.reference.folder) == ["alpha", "zed"])
        #expect(entries[0].failure == .manifestUnreadable && entries[0].displayName == "alpha" && entries[0].pack == nil)
        #expect(entries[1].pack?.displayName == "Blob" && entries[1].reference.key == "lunlet/zed")
        #expect(PetPackReader.scan(source: .codex, directory: root.appendingPathComponent("absent"), sheetSize: { _ in nil }).isEmpty)
        #expect(PetPackReference(key: "codex/blob") == PetPackReference(source: .codex, folder: "blob"))
        #expect(PetPackReference(key: "other/blob") == nil && PetPackReference(key: "codex/") == nil && PetPackReference(key: "codex/../x") == nil)
        #expect(PetPackReference(key: "lunlet/a/b")?.folder == nil)
    }

    // Refs: US-40, AC-40.02, AC-40.07. Packs arrive from other tools' folders, so the manifest is opened only as a
    // regular file within its limit: a pipe would stall the reader for good.
    @Test func aManifestThatIsAPipeIsRefusedWithoutWaitingOnIt() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makePack(in: root, folder: "pipe", manifest: nil)
        let path = directory.appendingPathComponent("pet.json").path
        #expect(mkfifo(path, 0o600) == 0)
        // Whatever happens, a writer lets a reader that is still waiting on the pipe return.
        defer { let writer = open(path, O_WRONLY | O_NONBLOCK); if writer >= 0 { close(writer) } }
        let outcome = Outcome(), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome.set(PetPackReader.read(reference: .init(source: .codex, folder: "pipe"), directory: directory, sheetSize: { _ in nil }))
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(outcome.value?.fault == .manifestUnreadable)
    }

    // Refs: US-40, AC-40.02, AC-40.07. A manifest over the limit is refused by its size, not loaded and then measured.
    @Test func aManifestOverTheLimitIsRefusedWithoutBeingLoaded() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makePack(in: root, folder: "huge", manifest: v1)
        // 512 MiB that occupy no disk: only reading them costs anything.
        let megabytes: UInt64 = 512
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("pet.json"))
        try handle.truncate(atOffset: megabytes * 1_048_576); try handle.close()
        let before = Footprint.current()
        let result = PetPackReader.read(reference: .init(source: .codex, folder: "huge"), directory: directory, sheetSize: { _ in nil })
        let peak = Footprint.lifetimePeak()
        #expect(result.fault == .manifestUnreadable)
        // The process's highest footprint so far stays well under what loading the file on top of `before` would take.
        #expect(peak < before + megabytes * 1_048_576 / 2, "the footprint peaked at \(peak / 1_048_576) MiB from \(before / 1_048_576) MiB")
    }

    @Test func rowsHoldTheirContractDurations() {
        #expect(PetSpriteRow.idle.durations == [0.28, 0.11, 0.11, 0.14, 0.14, 0.32] && abs(PetSpriteRow.idle.duration - 1.1) < 0.0001)
        #expect(PetSpriteRow.runningRight.frameCount == 8 && PetSpriteRow.runningRight.durations.last == 0.22)
        #expect(PetSpriteRow.waving.frameCount == 4 && PetSpriteRow.jumping.frameCount == 5 && PetSpriteRow.failed.frameCount == 8)
        #expect(PetSpriteRow.waiting.frameCount == 6 && PetSpriteRow.running.frameCount == 6 && PetSpriteRow.review.frameCount == 6)
        #expect(PetSpriteVersion.v1.sheetHeight == 1872 && PetSpriteVersion.v2.sheetHeight == 2288 && PetSpriteVersion.v2.sheetWidth == 1536)
    }

    @Test func posesMapToRowsAndLoopByTheirFrameDurations() {
        #expect(PetSpriteRule.row(for: .asleep) == .idle && PetSpriteRule.row(for: .idle) == .idle && PetSpriteRule.row(for: .working) == .running)
        #expect(PetSpriteRule.row(for: .waiting) == .waiting && PetSpriteRule.row(for: .done) == .review)
        // AC-40.03: Failed loops the failed row.
        #expect(PetSpriteRule.row(for: .failed) == .failed)
        var cue = PetSpriteCue(pose: .idle, poseChangedAt: 100)
        #expect(PetSpriteRule.frame(at: 100, cue: cue) == PetSpriteFrame(row: 0, column: 0))
        #expect(PetSpriteRule.frame(at: 100.3, cue: cue) == PetSpriteFrame(row: 0, column: 1))
        #expect(PetSpriteRule.frame(at: 100.7, cue: cue) == PetSpriteFrame(row: 0, column: 4))
        #expect(PetSpriteRule.frame(at: 101.15, cue: cue) == PetSpriteFrame(row: 0, column: 0))
        #expect(PetSpriteRule.nextChange(after: 100, cue: cue) == 100.28)
        #expect(PetSpriteRule.nextChange(after: 100.9, cue: cue).map { abs($0 - 101.1) < 0.0001 } == true)
        #expect(PetSpriteRule.frame(at: 103, cue: cue, reduceMotion: true) == PetSpriteFrame(row: 0, column: 0))
        #expect(PetSpriteRule.nextChange(after: 103, cue: cue, reduceMotion: true) == nil)
        cue.pose = .asleep
        #expect(PetSpriteRule.frame(at: 150, cue: cue) == PetSpriteFrame(row: 0, column: 0) && PetSpriteRule.nextChange(after: 150, cue: cue) == nil)
        cue.pose = .working
        #expect(PetSpriteRule.frame(at: 100.13, cue: cue) == PetSpriteFrame(row: 7, column: 1))
        cue.pose = .done
        #expect(PetSpriteRule.frame(at: 100, cue: cue).row == 8)
    }

    @Test func clicksJumpOnceDragsRunAndLookRowsFollowTheOffset() {
        var cue = PetSpriteCue(pose: .working, poseChangedAt: 0, jumpedAt: 200)
        #expect(PetSpriteRule.frame(at: 200.1, cue: cue) == PetSpriteFrame(row: 4, column: 0))
        #expect(PetSpriteRule.frame(at: 200.6, cue: cue).row == 4 && PetSpriteRule.frame(at: 200.6, cue: cue).column == 4)
        #expect(PetSpriteRule.frame(at: 200.9, cue: cue).row == 7)
        #expect(PetSpriteRule.nextChange(after: 200.1, cue: cue) == 200.14)
        #expect(PetSpriteRule.nextChange(after: 200.7, cue: cue).map { abs($0 - 200.84) < 0.0001 } == true)
        cue.drag = .left; cue.dragStartedAt = 300
        #expect(PetSpriteRule.frame(at: 300.5, cue: cue) == PetSpriteFrame(row: 2, column: 4))
        cue.drag = .right
        #expect(PetSpriteRule.frame(at: 300, cue: cue).row == 1)
        cue.drag = nil; cue.jumpedAt = nil; cue.pose = .idle; cue.hasLookRows = true
        cue.lookX = 0; cue.lookY = -1
        #expect(PetSpriteRule.frame(at: 400, cue: cue) == PetSpriteFrame(row: 9, column: 0))
        cue.lookX = 1; cue.lookY = 0
        #expect(PetSpriteRule.frame(at: 400, cue: cue) == PetSpriteFrame(row: 9, column: 4))
        cue.lookX = 0; cue.lookY = 1
        #expect(PetSpriteRule.frame(at: 400, cue: cue) == PetSpriteFrame(row: 10, column: 0))
        cue.lookX = -1; cue.lookY = 0
        #expect(PetSpriteRule.frame(at: 400, cue: cue) == PetSpriteFrame(row: 10, column: 4) && PetSpriteRule.nextChange(after: 400, cue: cue) == nil)
        cue.lookX = -0.7; cue.lookY = -0.7
        #expect(PetSpriteRule.frame(at: 400, cue: cue) == PetSpriteFrame(row: 10, column: 6))
        cue.lookX = 0.05; cue.lookY = 0.05
        #expect(PetSpriteRule.frame(at: 400, cue: cue).row == 0)
        cue.hasLookRows = false; cue.lookX = 1; cue.lookY = 0
        #expect(PetSpriteRule.frame(at: 400, cue: cue).row == 0)
        cue.pose = .waiting; cue.hasLookRows = true
        #expect(PetSpriteRule.frame(at: 400, cue: cue).row == 6)
    }
}
