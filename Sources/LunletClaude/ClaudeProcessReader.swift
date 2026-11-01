// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.07.
import Darwin
import Foundation

struct ClaudeProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}
enum ClaudeProcessCheck: Equatable, Sendable {
    case verified(ClaudeProcessIdentity)
    /// No such process, another user's process, a different start time or a different program: the record is stale.
    case stale
    /// Inspection failed; the record is neither accepted nor retired.
    case unknown
}
enum ClaudeProcessPresence: Sendable { case same, ended, unknown }

protocol ClaudeProcessInspecting: Sendable {
    func verify(pid: Int32, startedAt: Date) -> ClaudeProcessCheck
    func presence(of process: ClaudeProcessIdentity) -> ClaudeProcessPresence
}

/// Native libproc checks only: no shell tools, environment reads or terminal inspection.
struct ClaudeProcessReader: ClaudeProcessInspecting {
    /// `procStart` has whole-second precision.
    static let startTolerance: Double = 1

    func verify(pid: Int32, startedAt: Date) -> ClaudeProcessCheck {
        guard pid > 0 else { return .stale }
        guard let info = Self.info(pid) else { return kill(pid, 0) != 0 && errno == ESRCH ? .stale : .unknown }
        guard info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return .stale }
        guard abs(Double(info.pbi_start_tvsec) - startedAt.timeIntervalSince1970) <= Self.startTolerance else { return .stale }
        guard let executable = Self.executablePath(pid) else { return .unknown }
        guard Self.isClaudeExecutable(executable, script: { Self.scriptArgument(pid) }) else { return .stale }
        let identity = Self.identity(info)
        return presence(of: identity) == .same ? .verified(identity) : .stale
    }

    func presence(of process: ClaudeProcessIdentity) -> ClaudeProcessPresence {
        if let current = Self.info(process.pid) {
            guard current.pbi_uid == getuid() else { return .ended }
            return Self.identity(current) == process && current.pbi_status != UInt32(SZOMB) ? .same : .ended
        }
        return kill(process.pid, 0) != 0 && errno == ESRCH ? .ended : .unknown
    }

    /// The native installer links `~/.local/bin/claude` to a versioned binary under `claude/versions`;
    /// npm installs run a package script under an interpreter. Anything else is not Claude Code.
    static func isClaudeExecutable(_ path: String, script: () -> String?) -> Bool {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "claude" || path.contains("/@anthropic-ai/claude-code/") { return true }
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "versions", parent.deletingLastPathComponent().lastPathComponent == "claude" { return true }
        guard ["node", "bun"].contains(url.lastPathComponent), let script = script() else { return false }
        return script.contains("/@anthropic-ai/claude-code/")
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
    }
    static func identity(_ info: proc_bsdinfo) -> ClaudeProcessIdentity {
        .init(pid: Int32(info.pbi_pid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    /// Only an interpreter's first argument, its script path, is decoded. Later arguments can
    /// hold prompts and the environment follows them; neither is decoded or retained.
    static func scriptArgument(_ pid: Int32) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2_097_152 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > 4, size <= data.count else { return nil }
        return scriptArgument(from: data.prefix(size))
    }
    static func scriptArgument(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 2, argc <= 1_024, let executableEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        var cursor = executableEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for index in 0..<2 {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0), end - cursor <= 4_096 else { return nil }
            if index == 1 { return String(decoding: bytes[cursor..<end], as: UTF8.self) }
            cursor = end + 1
        }
        return nil
    }
}
