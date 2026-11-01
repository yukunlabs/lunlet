// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-04, AC-04.02, AC-04.11; US-32, AC-32.01.
import Foundation

/// Parses rollout record timestamps for session activity and usage accounting.
/// `ISO8601DateFormatter` is thread-safe, so one shared pair serves every reader.
final class RolloutTimestamps: @unchecked Sendable {
    static let shared = RolloutTimestamps()
    private let whole = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    func date(from value: String) -> Date? { fractional.date(from: value) ?? whole.date(from: value) }
}
