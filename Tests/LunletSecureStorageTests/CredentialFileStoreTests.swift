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
        // A file that grew past the file bound after it was written, or that is not a JSON document at all, is
        // rejected rather than read.
        try await store.perform(.storageSave) { try $0.save(Data("{}".utf8)) }
        let oversize = Data("{\"a\":\"".utf8) + Data(repeating: 0x20, count: CredentialFileStore.maximumFileBytes) + Data("\"}".utf8)
        for bytes in [oversize, Data(repeating: 0x20, count: 64)] {
            try bytes.write(to: store.file)
            await #expect(throws: SecureStorageFailure(status: errSecDecode)) {
                try await store.perform(.storageLoad) { try $0.load() }
            }
        }
    }

    // Owner decision of 2026-11-01: the file is sealed with a key bound to this Mac and user account, so a copy
    // taken elsewhere, a backup or a secret scanner sees no token; a process running as the user is not kept out.
    @Test func savedFileHoldsNoPlaintextAndReadsBackUnderTheSameBinding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = CredentialBinding.fixed(Data("machine-a:501".utf8))
        let store = CredentialFileStore(service: "com.lunlet.tests.sealed", directory: directory, binding: binding)
        let payload = Data("{\"token\":\"synthetic-secret-1234\"}".utf8)
        try await store.perform(.storageSave) { try $0.save(payload) }
        let bytes = try Data(contentsOf: store.file)
        #expect(bytes.range(of: Data("synthetic-secret".utf8)) == nil)
        let envelope = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(envelope.keys) == ["format", "version", "binding", "salt", "sealed"])
        #expect(envelope["format"] as? String == "com.lunlet.credential-envelope")
        #expect(try await store.perform(.storageLoad) { try $0.load() } == payload)
        // Each save uses fresh salt and nonce: the same payload never seals to the same bytes.
        try await store.perform(.storageSave) { try $0.save(payload) }
        #expect(try Data(contentsOf: store.file) != bytes)
        #expect(try await store.perform(.storageLoad) { try $0.load() } == payload)
    }

    @Test func aFileSealedForAnotherMacOrUserIsRefusedAndLeftIntact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let here = CredentialFileStore(service: "com.lunlet.tests.moved", directory: directory,
                                       binding: .fixed(Data("machine-a:501".utf8)))
        let elsewhere = CredentialFileStore(service: "com.lunlet.tests.moved", directory: directory,
                                            binding: .fixed(Data("machine-b:501".utf8)))
        let payload = Data("{\"token\":\"synthetic\"}".utf8)
        try await here.perform(.storageSave) { try $0.save(payload) }
        let sealed = try Data(contentsOf: here.file)
        await #expect(throws: SecureStorageFailure(status: errSecDecode)) {
            try await elsewhere.perform(.storageLoad) { try $0.load() }
        }
        #expect(try Data(contentsOf: here.file) == sealed)
        #expect(try await here.perform(.storageLoad) { try $0.load() } == payload)
    }

    @Test func aPlaintextFileFromAnEarlierBuildIsReadOnceAndSealedInPlace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialFileStore(service: "com.lunlet.tests.legacy", directory: directory,
                                        binding: .fixed(Data("machine-a:501".utf8)))
        let payload = Data("{\"applicationID\":\"cli_synthetic\",\"secret\":\"synthetic\"}".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: store.file.path, contents: payload, attributes: [.posixPermissions: 0o600]))
        #expect(try await store.perform(.storageLoad) { try $0.load() } == payload)
        let after = try Data(contentsOf: store.file)
        #expect(after != payload)
        #expect(after.range(of: Data("synthetic".utf8)) == nil)
        #expect(try permissions(store.file) == 0o600)
        #expect(try await store.perform(.storageLoad) { try $0.load() } == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["com.lunlet.tests.legacy.json"])
    }

    @Test func anEnvelopeMovedToAnotherServiceOrAlteredIsRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = CredentialBinding.fixed(Data("machine-a:501".utf8))
        let slack = CredentialFileStore(service: "com.lunlet.tests.slack", directory: directory, binding: binding)
        let telegram = CredentialFileStore(service: "com.lunlet.tests.telegram", directory: directory, binding: binding)
        try await slack.perform(.storageSave) { try $0.save(Data("{\"token\":\"synthetic\"}".utf8)) }
        let sealed = try Data(contentsOf: slack.file)
        #expect(FileManager.default.createFile(atPath: telegram.file.path, contents: sealed, attributes: [.posixPermissions: 0o600]))
        await #expect(throws: SecureStorageFailure(status: errSecDecode)) {
            try await telegram.perform(.storageLoad) { try $0.load() }
        }
        var envelope = try #require(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        envelope["salt"] = Data(repeating: 1, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: slack.file)
        await #expect(throws: SecureStorageFailure(status: errSecDecode)) {
            try await slack.perform(.storageLoad) { try $0.load() }
        }
    }

    @Test func theMachineBindingIsStableOnThisMacAndUser() throws {
        let first = try CredentialBinding.machine.material()
        #expect(first == (try CredentialBinding.machine.material()))
        #expect(first.count >= 36)
        #expect(CredentialBinding.machine.kind == "machine")
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
