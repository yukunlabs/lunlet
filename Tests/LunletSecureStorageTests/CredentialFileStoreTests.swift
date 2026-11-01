// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-20, AC-20.04, AC-20.06; US-12, AC-12.02; US-26, AC-26.02.
import Foundation
import Security
import Testing
@testable import LunletSecureStorage

struct CredentialFileStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-credentials-" + UUID().uuidString, isDirectory: true)
        return url
    }
    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func savesUserOnlyFilesInAUserOnlyDirectoryAndReadsThemBack() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialFileStore(service: "com.lunlet.tests.feishu", directory: directory)
        #expect(try await store.perform(.storageLoad) { try $0.load() } == nil)
        try await store.perform(.storageSave) { try $0.save(Data("{\"token\":\"synthetic\"}".utf8)) }
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(store.file) == 0o600)
        #expect(try await store.perform(.storageLoad) { try $0.load() } == Data("{\"token\":\"synthetic\"}".utf8))
        // A replacement lands whole: the file never holds a mix of old and new bytes, and no temporary file stays.
        try await store.perform(.storageSave) { try $0.save(Data("{\"token\":\"replacement\"}".utf8)) }
        #expect(try await store.perform(.storageLoad) { try $0.load() } == Data("{\"token\":\"replacement\"}".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["com.lunlet.tests.feishu.json"])
        try await store.perform(.storageRemove) { try $0.remove() }
        #expect(try await store.perform(.storageLoad) { try $0.load() } == nil)
        try await store.perform(.storageRemove) { try $0.remove() }  // Removing twice is not an error.
    }

    @Test func servicesAreSeparateFilesAndWidenedPermissionsAreNarrowedBeforeReading() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slack = CredentialFileStore(service: "com.lunlet.tests.slack", directory: directory)
        let telegram = CredentialFileStore(service: "com.lunlet.tests.telegram", directory: directory)
        try await slack.perform(.storageSave) { try $0.save(Data("{\"a\":1}".utf8)) }
        #expect(try await telegram.perform(.storageLoad) { try $0.load() } == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: slack.file.path)
        #expect(try await slack.perform(.storageLoad) { try $0.load() } == Data("{\"a\":1}".utf8))
        #expect(try permissions(slack.file) == 0o600)
    }

    @Test func emptyOversizeAndUnreadableContentIsRefusedWithoutWriting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialFileStore(service: "com.lunlet.tests.bounds", directory: directory)
        for data in [Data(), Data(repeating: 0x7b, count: CredentialFileStore.maximumBytes + 1)] {
            await #expect(throws: SecureStorageFailure(status: errSecParam)) {
                try await store.perform(.storageSave) { try $0.save(data) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        // A file that grew past the bound after it was written is rejected rather than read.
        try await store.perform(.storageSave) { try $0.save(Data("{}".utf8)) }
        try Data(repeating: 0x20, count: CredentialFileStore.maximumBytes + 1).write(to: store.file)
        await #expect(throws: SecureStorageFailure(status: errSecDecode)) {
            try await store.perform(.storageLoad) { try $0.load() }
        }
    }

    @Test func concurrentSavesOfOneServiceAreSerializedAndLeaveAWholeFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialFileStore(service: "com.lunlet.tests.race", directory: directory)
        let payloads = (0..<24).map { Data("{\"n\":\(String(repeating: "\($0 % 10)", count: 2_000))}".utf8) }
        await withTaskGroup(of: Void.self) { group in
            for payload in payloads { group.addTask { try? await store.perform(.storageSave) { try $0.save(payload) } } }
        }
        let final = try await store.perform(.storageLoad) { try $0.load() }
        #expect(payloads.contains(try #require(final)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["com.lunlet.tests.race.json"])
    }
}
