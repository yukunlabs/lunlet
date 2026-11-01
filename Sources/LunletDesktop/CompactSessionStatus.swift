// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.03, AC-02.05; US-21, AC-21.02; US-33, AC-33.01.
import LunletCore

/// Presentation only: confirmed activity never establishes original-client authority.
struct CompactSessionStatus: Equatable {
    let waiting: Int?
    let running: Int?
    let partial: Bool
    /// The monitored agent, or a generic name when several are monitored.
    let label: String

    static let unavailable = CompactSessionStatus(snapshots: [], available: false, partial: false)

    init(snapshots: [SessionSnapshot], available: Bool, partial: Bool, label: String = "Codex") {
        self.partial = available && partial; self.label = label
        // Ended sessions and child tasks have no waiting state of their own; only current conversations count.
        let current = snapshots.filter { $0.parentSessionID == nil && !$0.isEnded }
        let confirmed = available && !partial && current.allSatisfy {
            $0.hasConfirmedActivity && $0.observation.phase != .unknown
        }
        waiting = confirmed ? current.filter(\.awaitsUser).count : nil
        running = confirmed ? current.filter { $0.inputPending || $0.observation.phase == .running }.count : nil
    }
    var badge: String {
        guard let waiting else { return "" }
        return waiting == 0 ? "" : waiting > 9 ? "9+" : String(waiting)
    }
    var description: String {
        guard let waiting, let running else {
            return partial ? label + " · Session coverage incomplete; waiting count unknown"
                : label + " · Session status unavailable; waiting count unknown"
        }
        return label + " · \(waiting) waiting · \(running) running"
    }
}
