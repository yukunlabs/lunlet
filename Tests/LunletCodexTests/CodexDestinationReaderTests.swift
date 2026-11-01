// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.02, AC-03.03; US-11, AC-11.03.
import Foundation
import Testing
@testable import LunletCodex

private let workspace = "11111111-1111-4111-8111-111111111111"
private let terminal = "22222222-2222-4222-8222-222222222222"

@Test func destinationMetadataDecodesOnlyExplicitNavigationKeys() {
    let raw = Data((["/usr/bin/codex", "", "codex", "--model", "synthetic", "", "SUPERSET_WORKSPACE_ID=" + workspace,
                     "SUPERSET_TERMINAL_ID=" + terminal, "SECRET=synthetic-do-not-retain", "PATH=/synthetic", ""])
        .joined(separator: "\0").utf8)
    var argc: Int32 = 3
    var bytes = withUnsafeBytes(of: &argc) { Data($0) }; bytes.append(raw)
    let values = CodexDestinationReader.navigationMetadata(bytes)
    #expect(values == ["SUPERSET_WORKSPACE_ID": workspace, "SUPERSET_TERMINAL_ID": terminal])
    var conflicting = bytes
    conflicting.append(Data(("SUPERSET_TERMINAL_ID=" + workspace + "\0").utf8))
    #expect(CodexDestinationReader.navigationMetadata(conflicting) == nil)
    #expect(CodexDestinationReader.navigationMetadata(Data([1, 2, 3])) == nil)
}

@Test func destinationRequiresActualHostAndBuildsOnlyAnExistingSessionRevealURL() throws {
    let app = URL(fileURLWithPath: "/Applications/Superset.app")
    let values = ["SUPERSET_WORKSPACE_ID": workspace, "SUPERSET_TERMINAL_ID": terminal]
    let result = try #require(CodexDestinationReader.resolve(applicationID: "com.superset.desktop", applicationURL: app,
                                 applicationPID: 42, metadata: values))
    let components = try #require(URLComponents(url: result.revealURL, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "superset" && components.host == "v2-workspace")
    #expect(components.path == "/" + workspace)
    #expect(components.queryItems?.first(where: { $0.name == "terminalId" })?.value == terminal)
    #expect(components.queryItems?.contains(where: { $0.name == "focusRequestId" }) == true)
    #expect(result.applicationURL == app && result.applicationPID == 42)
    #expect(CodexDestinationReader.resolve(applicationID: "com.apple.Terminal", applicationURL: app,
                                          applicationPID: 42, metadata: values) == nil)
    #expect(CodexDestinationReader.resolve(applicationID: "com.superset.desktop", applicationURL: app,
                                          applicationPID: 42, metadata: ["SUPERSET_WORKSPACE_ID": workspace]) == nil)
    #expect(CodexDestinationReader.resolve(applicationID: "com.superset.desktop", applicationURL: app,
                                          applicationPID: 42, metadata: ["SUPERSET_WORKSPACE_ID": "../other", "SUPERSET_TERMINAL_ID": terminal]) == nil)
}

@Test func iTermRevealKeepsItsSessionIdentifierWithoutRunningACommand() throws {
    let session = "w0t0p0:" + terminal
    let result = try #require(CodexDestinationReader.resolve(applicationID: "com.googlecode.iterm2",
        applicationURL: URL(fileURLWithPath: "/Applications/iTerm.app"), applicationPID: 42,
        metadata: ["ITERM_SESSION_ID": session]))
    let components = try #require(URLComponents(url: result.revealURL, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "iterm2" && components.path == "reveal")
    #expect(components.queryItems == [URLQueryItem(name: "sessionid", value: session)])
    #expect(CodexDestinationReader.resolve(applicationID: "com.googlecode.iterm2", applicationURL: result.applicationURL,
        applicationPID: 42, metadata: ["ITERM_SESSION_ID": "unsafe?c=command"]) == nil)
}
