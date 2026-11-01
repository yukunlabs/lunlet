// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-18, AC-18.01, AC-18.02, AC-18.03; US-33, AC-33.04.
// Refs: US-25, AC-25.02.
// Refs: US-23, AC-23.01.
// Refs: US-04, AC-04.01, AC-04.02, AC-04.03, AC-04.05, AC-04.08; US-12, AC-12.04.
import Combine
import Foundation
import LunletCodex
import LunletCore

@MainActor final class LocalUsageModel: ObservableObject {
    @Published private(set) var snapshot: LocalUsageHistory?
    @Published private(set) var isLoading = false
    @Published private(set) var unavailable = false
    @Published private(set) var historyDays = 5
    @Published private(set) var lastSuccessfulRefresh: Date?
    private let now: @MainActor () -> Date
    private let reader: any LocalUsageReading
    private var operation: Task<Void, Never>?
    private var lastAttempt: ContinuousClock.Instant?
    private var closed = false
    private var rangeRevision = UUID()

    init(reader: any LocalUsageReading = CodexLocalUsageReader(), now: @escaping @MainActor () -> Date = Date.init) {
        self.reader = reader; self.now = now
    }
    func refreshIfNeeded() {
        guard lastAttempt.map({ ContinuousClock.now - $0 >= .seconds(300) }) ?? true else { return }
        refresh()
    }
    func refresh() {
        guard !closed, operation == nil else { return }
        lastAttempt = .now; isLoading = true; unavailable = false
        let days = historyDays, revision = rangeRevision
        operation = Task {
            defer {
                isLoading = false; operation = nil
                if !closed, rangeRevision != revision { refresh() }
            }
            do {
                let value = try await reader.readHistory(now: now(), calendar: .current, days: days)
                try Task.checkCancellation()
                guard !closed else { return }
                snapshot = value
                lastSuccessfulRefresh = now()
            } catch {
                guard !closed, !Task.isCancelled else { return }
                snapshot = nil; unavailable = true
            }
        }
    }
    func setHistoryDays(_ days: Int) {
        guard !closed, (1...7).contains(days), days != historyDays else { return }
        historyDays = days; rangeRevision = UUID(); snapshot = nil
        if let operation { operation.cancel() } else { refresh() }
    }
    func shutdown() async {
        closed = true; operation?.cancel(); await operation?.value
        operation = nil; snapshot = nil; isLoading = false
    }
}

enum LocalUsageText {
    static func tokens(_ amount: LocalUsageAmount?) -> String {
        guard let value = amount?.tokens else { return "— tokens" }
        return (amount?.partial == true ? "≥" : "") + value.formatted(.number.notation(.compactName)) + " tokens"
    }
    static func cost(_ amount: LocalUsageAmount?) -> String {
        guard let value = amount?.estimatedUSD else { return "Cost unavailable" }
        let prefix = amount?.costPartial == true ? "≥$" : "≈$"
        let locale = Locale(identifier: "en_US")
        if value > 0 && value < 0.0001 {
            return prefix + String(format: "%.0e", locale: locale, value).lowercased()
        }
        return prefix + value.formatted(.number.locale(locale)
            .precision(.fractionLength(value > 0 && value < 0.01 ? 4 : 2)))
    }
    /// A bounded bar label; exact USD and price coverage are available in help text.
    static func costBar(_ amount: LocalUsageAmount) -> String {
        guard let value = amount.estimatedUSD else { return "—" }
        let prefix = amount.costPartial ? "≥$" : "≈$"
        let locale = Locale(identifier: "en_US_POSIX")
        for (scale, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] {
            if value >= scale { return prefix + String(format: "%.1f", locale: locale, value / scale) + suffix }
        }
        if value > 0 && value < 0.0001 {
            return prefix + String(format: "%.0e", locale: locale, value).lowercased()
        }
        return prefix + value.formatted(.number.locale(locale).grouping(.never)
            .precision(.fractionLength(value > 0 && value < 0.01 ? 4 : 2)))
    }
    static func coverage(_ amounts: [LocalUsageAmount]) -> String {
        // Double avoids overflow when summarizing independent sessions or day buckets.
        let priced = amounts.reduce(0.0) { $0 + Double($1.pricedTokens) }
        let unpriced = amounts.reduce(0.0) { $0 + Double($1.unpricedTokens) }
        guard priced + unpriced > 0 else { return "Price coverage unavailable." }
        let percent = (100 * priced / (priced + unpriced)).formatted(.number.precision(.fractionLength(0...1)))
        return "Prices cover " + percent + "% of recorded tokens."
    }
    static func costHelp(_ amount: LocalUsageAmount, provider: SessionProvider = .codex) -> String {
        let exact = amount.estimatedUSD.map { (amount.costPartial ? "≥$" : "≈$") + String($0) }
            ?? "Cost unavailable"
        // Claude transcripts omit some usage, so its recorded amounts are lower bounds.
        let estimate = exact + (provider == .claude ? " USD · API list-price estimate of recorded usage, a lower bound, not a bill."
            : " USD · standard API estimate, not a bill.")
        let subtotal = amount.costPartial && amount.estimatedUSD != nil ? " Known subtotal; excluded usage remains unavailable." : ""
        return estimate + subtotal + " " + coverage([amount])
    }

}
