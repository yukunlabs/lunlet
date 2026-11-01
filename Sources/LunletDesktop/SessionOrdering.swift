// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-23, AC-23.01, AC-23.02; US-02, AC-02.05.
import Foundation
import LunletCore

// Refs: US-02, AC-02.02, AC-02.08.
struct SessionIdentityLabels {
    private let ids: Set<UUID>
    init<S: Sequence>(ids: S) where S.Element == UUID { self.ids = Set(ids) }
    func label(for id: UUID) -> String {
        let value = id.uuidString.replacingOccurrences(of: "-", with: "")
        let others = ids.subtracting([id]).map { $0.uuidString.replacingOccurrences(of: "-", with: "") }
        for length in 8...value.count {
            let suffix = String(value.suffix(length))
            if !others.contains(where: { $0.hasSuffix(suffix) }) { return suffix }
        }
        return value
    }
}

/// Presentation only: never changes session lifecycle, bindings or hidden work.
struct SessionOrdering {
    func apply(to snapshots: [SessionSnapshot], recentFirst: Bool = false) -> [SessionSnapshot] {
        snapshots.sorted {
            if recentFirst {
                switch ($0.lastActivityAt, $1.lastActivityAt) {
                case (.some(let left), .some(let right)) where left != right: return left > right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return $0.observation.sessionID.uuidString < $1.observation.sessionID.uuidString
                }
            }
            let left = priority($0), right = priority($1)
            if left != right { return left < right }
            let leftKey = [$0.project, $0.title, $0.observation.sessionID.uuidString].joined(separator: "\u{0}")
            let rightKey = [$1.project, $1.title, $1.observation.sessionID.uuidString].joined(separator: "\u{0}")
            return leftKey < rightKey
        }
    }
    private func priority(_ snapshot: SessionSnapshot) -> Int {
        guard snapshot.hasConfirmedActivity else { return 2 }
        if snapshot.awaitsUser { return 0 }
        return snapshot.inputPending || snapshot.observation.phase == .running ? 1 : 2
    }
}
