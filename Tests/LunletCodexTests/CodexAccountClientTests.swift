// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05, AC-04.06, AC-04.09.
import Darwin
import Foundation
import Testing
@testable import LunletCodex

private struct FakeCodex {
    let directory: URL
    let executable: URL

    init(_ scenario: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-account-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        executable = directory.appendingPathComponent(scenario)
        let source = try #require(Bundle.module.url(forResource: "fake_codex", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func checkChildExited() throws {
        let file = directory.appendingPathComponent("child.pid")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let pid = try #require(Int32(String(contentsOf: file, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}

@Test func accountReadsInitializeAndRequestOnlyOfficialLimits() async throws {
    let fake = try FakeCodex("success")
    defer { try? FileManager.default.removeItem(at: fake.directory) }
    let result = try await CodexAccountClient(executableURL: fake.executable).readLimits()
    #expect(result.buckets.first?.primary?.usedPercent == 25)
    #expect(result.identity?.email == "developer@example.invalid")
    try fake.checkChildExited()
}

@Test func unrelatedResponseIDsCannotReplaceTheCurrentAccountResult() async throws {
    let fake = try FakeCodex("wrong-id")
    defer { try? FileManager.default.removeItem(at: fake.directory) }
    let result = try await CodexAccountClient(executableURL: fake.executable).readLimits()
    #expect(result.buckets.first?.primary?.usedPercent == 25)
    try fake.checkChildExited()
}

@Test func processFailuresAreBoundedAndDoNotExposeProviderDetails() async throws {
    for (scenario, expected) in [("rpc-error", CodexAccountFailure.requestFailed), ("malformed", .invalidResponse),
                                 ("broken-pipe", .unavailable), ("timeout", .timeout)] {
        let fake = try FakeCodex(scenario)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        do {
            _ = try await CodexAccountClient(executableURL: fake.executable, timeout: scenario == "timeout" ? 2 : 15).readLimits()
            Issue.record("A failed account read cannot return verified usage")
        } catch {
            #expect(error as? CodexAccountFailure == expected)
            #expect(!String(describing: error).contains("synthetic-private-provider-detail"))
        }
        if scenario == "timeout" {
            #expect(FileManager.default.fileExists(atPath: fake.directory.appendingPathComponent("waiting").path))
        }
        try fake.checkChildExited()
    }
}

@Test func cancellationClosesTheOwnedAccountSubprocess() async throws {
    let fake = try FakeCodex("cancel")
    defer { try? FileManager.default.removeItem(at: fake.directory) }
    let task = Task { try await CodexAccountClient(executableURL: fake.executable).readLimits() }
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: fake.directory.appendingPathComponent("waiting").path),
          ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancellation must not return a usage snapshot")
    } catch {
        #expect(error is CancellationError)
    }
    try fake.checkChildExited()
}

@Test func scriptLaunchersFindTheirInterpreterBesideTheExecutable() async throws {
    // Package managers install `#!/usr/bin/env <interpreter>` launchers beside an interpreter a GUI PATH lacks.
    let fake = try FakeCodex("success")
    defer { try? FileManager.default.removeItem(at: fake.directory) }
    let interpreter = fake.directory.appendingPathComponent("lunlet-synthetic-interpreter")
    try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
    let source = try String(contentsOf: fake.executable, encoding: .utf8)
    try ("#!/usr/bin/env lunlet-synthetic-interpreter" + source.drop { $0 != "\n" })
        .write(to: fake.executable, atomically: true, encoding: .utf8)
    for file in [interpreter, fake.executable] {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let result = try await CodexAccountClient(executableURL: fake.executable).readLimits()
    #expect(result.buckets.first?.primary?.usedPercent == 25)
    try fake.checkChildExited()
}

@Test func executableSearchCoversBoundedUserInstallLocationsWithoutAShell() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-account-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for version in ["v9.0.0", "v20.11.1", "v18.2.0"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                                                withIntermediateDirectories: true)
    }
    let inherited = home.appendingPathComponent("inherited")
    try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
    let launcher = inherited.appendingPathComponent("codex")
    try "#!/bin/sh\n".write(to: launcher, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

    let environment = ["PATH": "\(inherited.path):relative/bin:/usr/bin", "HOME": home.path]
    let directories = CodexAccountClient.searchDirectories(environment: environment, home: home)
    #expect(directories.prefix(2) == [inherited.path, "/usr/bin"])
    #expect(!directories.contains("relative/bin"))
    #expect(directories.contains(home.appendingPathComponent(".local/bin").path))
    #expect(directories.filter { $0.contains("/.nvm/") }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
        == ["v20.11.1", "v18.2.0", "v9.0.0"])
    #expect(CodexAccountClient.findExecutable(environment: environment, home: home) == launcher)

    let child = CodexAccountClient.childEnvironment(for: launcher, environment: ["PATH": "/usr/bin", "HOME": home.path], home: home)
    let path = child["PATH"]?.split(separator: ":").map(String.init) ?? []
    #expect(path.first == inherited.path)
    #expect(path.count == Set(path).count)
    #expect(child["HOME"] == home.path)
}
