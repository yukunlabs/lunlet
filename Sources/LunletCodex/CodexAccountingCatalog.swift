// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.08; US-04, AC-04.11.
import Foundation
import os

struct CodexUsageRoots: Sendable {
    let homes: [URL]
    var complete = true
}

/// Shares discovered accounting roots within one app lifetime; stores no conversation content.
public final class CodexAccountingCatalog: Sendable {
    private struct State {
        var homes: Set<URL> = []
        var overflow = false
        var recorded = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Accounting roots tracked per app lifetime, shared by discovery and usage reading.
    static let maximumRoots = 32
    public init() {}

    /// Whether at least one process scan has been recorded, even one without roots.
    var hasRecordedScan: Bool { state.withLock { $0.recorded } }

    func record(_ files: [CodexRolloutFile]) {
        state.withLock { state in
            state.recorded = true
            for file in files {
                guard let root = CodexProcessReader.accountingRoot(for: file.url), !state.homes.contains(root) else { continue }
                guard state.homes.count < Self.maximumRoots else { state.overflow = true; return }
                state.homes.insert(root)
            }
        }
    }

    func snapshot() -> CodexUsageRoots {
        state.withLock { .init(homes: Array($0.homes), complete: !$0.overflow) }
    }

    /// Drops a root that no longer exists. Overflow stays sticky because dropped roots remain unknown.
    func forget(_ root: URL) {
        let path = root.standardizedFileURL.path
        state.withLock { state in state.homes = state.homes.filter { $0.standardizedFileURL.path != path } }
    }
}
