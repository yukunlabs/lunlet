// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.02, AC-03.03; US-11, AC-11.03.
import AppKit
import Darwin
import Foundation

/// A reveal URL is navigation only. It cannot grant remote input authority.
public struct CodexTerminalDestination: Equatable, Sendable {
    public let applicationID: String
    public let applicationURL: URL
    public let applicationPID: Int32
    public let revealURL: URL
}

struct CodexDestinationReader {
    func read(process: CodexProcessIdentity) -> CodexTerminalDestination? {
        let reader = CodexProcessReader()
        guard reader.presence(of: process) == .same,
              let info = CodexProcessReader.info(process.pid), info.pbi_uid == getuid(),
              CodexProcessReader.terminalAttached(process.pid, info: info) else { return nil }
        var pid = Int32(info.pbi_ppid), seen = Set<Int32>()
        for _ in 0..<32 {
            guard pid > 1, seen.insert(pid).inserted,
                  let ancestor = CodexProcessReader.info(pid), ancestor.pbi_uid == getuid() else { return nil }
            if let host = hostApplication(pid) {
                let (id, bundleURL, applicationPID) = host
                // The nearest actual host wins. Do not skip an unsupported host
                // to guess another application from inherited launch metadata.
                guard id == "com.superset.desktop" || id == "com.googlecode.iterm2",
                      let data = argumentData(process.pid), let metadata = Self.navigationMetadata(data),
                      reader.presence(of: process) == .same,
                      let current = CodexProcessReader.info(pid),
                      CodexProcessReader.identity(current) == CodexProcessReader.identity(ancestor) else { return nil }
                return Self.resolve(applicationID: id, applicationURL: bundleURL, applicationPID: applicationPID, metadata: metadata)
            }
            pid = Int32(ancestor.pbi_ppid)
        }
        return nil
    }

    private func hostApplication(_ pid: Int32) -> (String, URL, Int32)? {
        if let app = NSRunningApplication(processIdentifier: pid),
           let id = app.bundleIdentifier, let url = app.bundleURL { return (id, url, pid) }
        // A detached host can outlive an in-place application update. Recover its
        // kernel launch executable, then require one running app at that same
        // bundle location. A process name alone never establishes the host.
        guard let data = argumentData(pid), let executable = Self.launchExecutable(data) else { return nil }
        var url = executable.deletingLastPathComponent()
        while url.path != "/", url.pathExtension != "app" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              bundle.executableURL?.standardizedFileURL == executable.standardizedFileURL,
              let id = bundle.bundleIdentifier else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        }
        guard apps.count == 1, let app = apps.first else { return nil }
        return (id, url, app.processIdentifier)
    }

    static func launchExecutable(_ data: Data) -> URL? {
        guard let layout = ProcessArgumentLayout(data),
              let path = String(bytes: layout.bytes[layout.executable], encoding: .utf8), path.hasPrefix("/"),
              path.utf8.count <= 4096 else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func resolve(applicationID: String, applicationURL: URL, applicationPID: Int32,
                        metadata: [String: String]) -> CodexTerminalDestination? {
        var url = URLComponents()
        switch applicationID {
        case "com.superset.desktop":
            guard let workspace = metadata["SUPERSET_WORKSPACE_ID"], UUID(uuidString: workspace) != nil,
                  let terminal = metadata["SUPERSET_TERMINAL_ID"], UUID(uuidString: terminal) != nil else { return nil }
            url.scheme = "superset"; url.host = "v2-workspace"; url.path = "/" + workspace
            url.queryItems = [.init(name: "terminalId", value: terminal), .init(name: "focusRequestId", value: UUID().uuidString)]
        case "com.googlecode.iterm2":
            guard let session = metadata["ITERM_SESSION_ID"],
                  session.range(of: #"^(?:w[0-9]+t[0-9]+p[0-9]+:)?[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil,
                  UUID(uuidString: String(session.split(separator: ":").last ?? "")) != nil else { return nil }
            url.scheme = "iterm2"; url.path = "reveal"
            url.queryItems = [.init(name: "sessionid", value: session)]
        default: return nil
        }
        guard let revealURL = url.url else { return nil }
        return .init(applicationID: applicationID, applicationURL: applicationURL,
                     applicationPID: applicationPID, revealURL: revealURL)
    }

    // Navigation alone reads these three launch fields. Values of other keys are
    // never decoded, retained, or logged. Discovery continues to ignore all env.
    static func navigationMetadata(_ data: Data) -> [String: String]? {
        guard let layout = ProcessArgumentLayout(data) else { return nil }
        let bytes = layout.bytes
        var cursor = layout.environmentStart
        let keys: Set<String> = ["SUPERSET_WORKSPACE_ID", "SUPERSET_TERMINAL_ID", "ITERM_SESSION_ID"]
        var result: [String: String] = [:], entries = 0
        while cursor < bytes.count {
            guard entries < 16_384, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            entries += 1
            if let separator = bytes[cursor..<end].firstIndex(of: 61), separator - cursor <= 64 {
                let key = String(decoding: bytes[cursor..<separator], as: UTF8.self)
                if keys.contains(key) {
                    guard result[key] == nil, end - separator > 1, end - separator <= 257,
                          let value = String(bytes: bytes[(separator + 1)..<end], encoding: .utf8) else { return nil }
                    result[key] = value
                }
            }
            cursor = end + 1
        }
        return result
    }

    private func argumentData(_ pid: Int32) -> Data? { CodexProcessReader.argumentBuffer(pid) }
}
