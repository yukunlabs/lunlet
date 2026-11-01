// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.08; US-04, AC-04.11.
// Refs: US-03, AC-03.02, AC-03.03.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05, AC-02.06; US-11, AC-11.03, AC-11.05, AC-11.06.
// Refs: US-08, AC-08.01, AC-08.02; US-10, AC-10.04.
import Darwin
import Foundation

struct CodexProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}
/// A rollout record held open by a Codex process. Equality and hashing use the file
/// identity, so one record reached through two paths is one ownership claim; `url` is
/// its current path and is compared explicitly where a path change matters.
struct CodexRolloutFile: Hashable, Sendable {
    struct Identity: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }
    let url: URL
    let identity: Identity
    var device: Int32 { identity.device }
    var inode: UInt64 { identity.inode }
    init(url: URL, device: Int32, inode: UInt64) { self.url = url; identity = .init(device: device, inode: inode) }
    static func == (left: Self, right: Self) -> Bool { left.identity == right.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
    /// The same record at the same current path, rather than merely the same identity.
    func isSamePath(as other: Self) -> Bool { self == other && url == other.url }
}
enum CodexProcessRole: Sendable { case terminalCLI, sharedRuntime }
struct CodexProcessCandidate: Sendable {
    let process: CodexProcessIdentity
    let files: [CodexRolloutFile]
    let role: CodexProcessRole
    init(process: CodexProcessIdentity, files: [CodexRolloutFile], role: CodexProcessRole = .terminalCLI) {
        self.process = process; self.files = files; self.role = role
    }
}
struct CodexProcessScan: Sendable {
    let candidates: [CodexProcessCandidate]
    let complete: Bool
}
enum CodexProcessPresence: Sendable { case same, ended, unknown }
protocol CodexProcessInspecting: Sendable {
    func scan() throws -> CodexProcessScan
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence
    /// The image the exact live process runs, never a PATH lookup; nil fails continuation closed.
    func executable(of process: CodexProcessIdentity) -> URL?
}
extension CodexProcessInspecting {
    func executable(of process: CodexProcessIdentity) -> URL? { nil }
}
enum CodexProcessReadFailure: Error { case unavailable }

/// Offsets into one bounded `KERN_PROCARGS2` buffer. Discovery decodes only the argc
/// arguments; only destination reading may scan environment entries, and only for keys
/// it names. Nothing else in the buffer is decoded, retained or logged.
struct ProcessArgumentLayout {
    static let maximumBytes = 2_097_152
    let bytes: [UInt8]
    let executable: Range<Int>
    let arguments: [Range<Int>]
    let environmentStart: Int

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes.count <= Self.maximumBytes else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...1024).contains(argc), let executableEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        var cursor = executableEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [Range<Int>] = []
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            arguments.append(cursor..<end); cursor = end + 1
        }
        self.bytes = bytes; executable = 4..<executableEnd; self.arguments = arguments; environmentStart = cursor
    }

    func decodedArguments() -> [String] { arguments.map { String(decoding: bytes[$0], as: UTF8.self) } }
}

struct CodexProcessReader: CodexProcessInspecting {
    private enum Budget {
        static let processIDs = 16_384
        static let descriptors = 8192
        static let scan: Duration = .seconds(3)
    }

    func scan() throws -> CodexProcessScan {
        var ids = [pid_t](repeating: 0, count: Budget.processIDs)
        let count = proc_listallpids(&ids, Int32(ids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { throw CodexProcessReadFailure.unavailable }
        var complete = Int(count) < ids.count
        var candidates: [CodexProcessCandidate] = []
        let deadline = ContinuousClock.now + Budget.scan
        for pid in ids.prefix(min(Int(count), ids.count)) where pid > 0 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { complete = false; break }
            guard var info = Self.info(pid), info.pbi_uid == getuid() else { continue }
            let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "codex" || name == "codex-cli" else { continue }
            guard let arguments = Self.arguments(pid) else { complete = false; continue }
            guard let role = Self.role(arguments: arguments, terminalAttached: Self.terminalAttached(pid, info: info)) else { continue }
            let identity = Self.identity(info)
            do {
                let files = try openRollouts(pid: pid)
                guard presence(of: identity) == .same else { complete = false; continue }
                candidates.append(.init(process: identity, files: files, role: role))
            } catch { complete = false }
        }
        return .init(candidates: candidates, complete: complete)
    }
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence {
        if let current = Self.info(process.pid) {
            guard current.pbi_uid == getuid() else { return .unknown }
            return Self.identity(current) == process && current.pbi_status != UInt32(SZOMB) ? .same : .ended
        }
        return kill(process.pid, 0) != 0 && errno == ESRCH ? .ended : .unknown
    }
    /// The kernel's path for the process image, so a shell function or PATH wrapper that launched
    /// the session is never re-run. The start time is checked on both sides of the lookup, so a
    /// reused PID cannot substitute another program.
    func executable(of process: CodexProcessIdentity) -> URL? {
        guard presence(of: process) == .same else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(process.pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0, Int(length) <= buffer.count, presence(of: process) == .same else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        var status = stat()
        guard path.hasPrefix("/"), stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              access(path, X_OK) == 0 else { return nil }
        return URL(fileURLWithPath: path)
    }
    func openRollouts(pid: Int32) throws -> [CodexRolloutFile] {
        guard let process = Self.info(pid), process.pbi_uid == getuid() else { throw CodexProcessReadFailure.unavailable }
        var descriptors = [proc_fdinfo](repeating: .init(), count: Budget.descriptors)
        let capacity = descriptors.count * MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity))
        guard bytes >= 0, bytes < capacity else { throw CodexProcessReadFailure.unavailable }
        var result = Set<CodexRolloutFile>()
        for entry in descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride) where entry.proc_fdtype == PROX_FDTYPE_VNODE {
            try Task.checkCancellation()
            var details = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &details, size) == size,
                  details.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: &details.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard path.contains("/sessions/"), path.hasSuffix(".jsonl") else { continue }
            result.insert(.init(url: URL(fileURLWithPath: path), device: Int32(bitPattern: details.pvip.vip_vi.vi_stat.vst_dev),
                                inode: details.pvip.vip_vi.vi_stat.vst_ino))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }
    /// Derive only a root already exposed by a native writable rollout descriptor.
    static func accountingRoot(for rollout: URL) -> URL? {
        let parts = rollout.standardizedFileURL.pathComponents
        guard rollout.pathExtension == "jsonl", let index = parts.lastIndex(of: "sessions"), index > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<index])), isDirectory: true)
    }

    static func terminalAttached(_ pid: Int32, info: proc_bsdinfo) -> Bool {
        (info.e_tdev != UInt32.max && info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0) || hasTerminalDescriptor(pid)
    }
    /// A PTY can be attached to standard input/output without being the process's
    /// controlling terminal. Verify the actual character device without reading
    /// terminal content or acquiring it as our own controlling terminal.
    private static func hasTerminalDescriptor(_ pid: Int32) -> Bool {
        for descriptor: Int32 in [0, 1] {
            var details = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &details, size) == size,
                  details.pvip.vip_vi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFCHR) else { continue }
            let path = withUnsafeBytes(of: &details.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard path.hasPrefix("/dev/") else { continue }
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var actual = stat()
            if fstat(fd, &actual) == 0,
               actual.st_dev == Int32(bitPattern: details.pvip.vip_vi.vi_stat.vst_dev),
               actual.st_ino == details.pvip.vip_vi.vi_stat.vst_ino,
               isatty(fd) == 1 { return true }
        }
        return false
    }

    static func role(arguments: [String], terminalAttached: Bool) -> CodexProcessRole? {
        // A service is observation-only; command names in prompts cannot select it.
        if subcommand(arguments) == "app-server" { return .sharedRuntime }
        return terminalAttached && isInteractive(arguments: arguments) ? .terminalCLI : .sharedRuntime
    }

    static func isInteractive(arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        // Every 0.166.0 command except `resume` and `fork` is a tool or service rather than an
        // interactive session; any other first word is the interactive CLI's optional prompt.
        let commands: Set<String> = ["agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server",
                                     "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a",
                                     "queue", "archive", "delete", "migrate-rollouts", "migrate-nfs-db", "unarchive", "cloud",
                                     "exec-server", "features", "help"]
        return subcommand(arguments).map { !commands.contains($0) } ?? true
    }
    private static func subcommand(_ arguments: [String]) -> String? {
        let valueFlags: Set<String> = ["-c", "--config", "-m", "--model", "-C", "--cd", "--remote", "--remote-auth-token-env",
                                       "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir",
                                       "--enable", "--disable", "--local-provider"]
        // `-i/--image <FILE>...` takes every following word until the next option.
        let multiValueFlags: Set<String> = ["-i", "--image"]
        var skip = false, values = false
        for arg in arguments.dropFirst() {
            if skip { skip = false; continue }
            if arg == "--" { return nil }
            if valueFlags.contains(arg) { skip = true; values = false; continue }
            if multiValueFlags.contains(arg) { values = true; continue }
            if arg.hasPrefix("-") { values = false; continue }
            if values { continue }
            return arg
        }
        return nil
    }
    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
    }
    static func identity(_ info: proc_bsdinfo) -> CodexProcessIdentity {
        .init(pid: Int32(info.pbi_pid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    /// The single bounded KERN_PROCARGS2 read shared by discovery and navigation.
    static func argumentBuffer(_ pid: Int32) -> Data? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= ProcessArgumentLayout.maximumBytes else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > 4, size <= data.count else { return nil }
        data.count = size
        return data
    }
    private static func arguments(_ pid: Int32) -> [String]? { argumentBuffer(pid).flatMap(arguments(from:)) }
    /// Exactly argc arguments; environment entries after them are never inspected or retained.
    static func arguments(from data: Data) -> [String]? { ProcessArgumentLayout(data)?.decodedArguments() }
}
