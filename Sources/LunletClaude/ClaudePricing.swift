// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.04; US-04, AC-04.02, AC-04.03.
import Foundation

/// Token categories of one recorded API response.
struct ClaudeTokenCounts: Equatable, Hashable, Sendable {
    var input: Int64 = 0
    var cacheWrite5m: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var total: Int64 { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
    /// Every input token of the request, including cache reads and writes.
    var prompt: Int64 { input + cacheWrite5m + cacheWrite1h + cacheRead }
    func merged(with other: Self) -> Self {
        .init(input: max(input, other.input), cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
              cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h), cacheRead: max(cacheRead, other.cacheRead),
              output: max(output, other.output))
    }
}

/// The billing-relevant modifiers recorded with a response. Only standard global usage is priced.
struct ClaudePricingKey: Equatable, Hashable, Sendable {
    let model: String
    let inferenceGeo: String?
    let speed: String?
    let serviceTier: String?
}

/// Published Claude API list prices in USD per million tokens, accessed 2026-10-30 from
/// https://platform.claude.com/docs/en/about-claude/pricing (model IDs from the models overview and
/// model-ID pages). An estimate of API-equivalent cost, not a subscription bill.
///
/// Applied: the 5-minute and 1-hour cache-write rates, per-model cache-read rates, Claude Haiku 5.5's
/// per-request prompt-length tier and the 1.1x US-only `inference_geo` multiplier for 4.6-and-later models.
/// Deliberately omitted, so those responses stay unpriced: fast mode, priority or batch service tiers,
/// unknown geographies, aliases and unlisted, retired or Mythos models, including Sonnet 4.5's long-context rules.
/// Server-tool charges such as web search are not token prices and are never added.
enum ClaudePricing {
    struct Rate: Equatable, Sendable {
        let input: Double, write5m: Double, write1h: Double, read: Double, output: Double
    }
    private struct Model {
        let standard: Rate
        /// Claude Haiku 5.5 prices a request whose prompt exceeds 100,000 tokens at this rate.
        var longPrompt: Rate? = nil
        /// The US-only multiplier applies to Claude 4.6 and later models.
        var supportsUSGeography = true
    }
    private static let models: [String: Model] = [
        "claude-fable-5-1": .init(standard: .init(input: 10, write5m: 12.50, write1h: 20, read: 0.25, output: 50)),
        "claude-fable-5": .init(standard: .init(input: 10, write5m: 12.50, write1h: 20, read: 1, output: 50)),
        "claude-opus-5-5": .init(standard: .init(input: 4, write5m: 5, write1h: 8, read: 0.20, output: 20)),
        "claude-opus-5": .init(standard: .init(input: 5, write5m: 6.25, write1h: 10, read: 0.50, output: 25)),
        "claude-opus-4-8": .init(standard: .init(input: 5, write5m: 6.25, write1h: 10, read: 0.50, output: 25)),
        "claude-opus-4-7": .init(standard: .init(input: 5, write5m: 6.25, write1h: 10, read: 0.50, output: 25)),
        "claude-opus-4-6": .init(standard: .init(input: 5, write5m: 6.25, write1h: 10, read: 0.50, output: 25)),
        "claude-sonnet-5-5": .init(standard: .init(input: 2, write5m: 2.50, write1h: 4, read: 0.10, output: 10)),
        "claude-sonnet-5": .init(standard: .init(input: 2, write5m: 2.50, write1h: 4, read: 0.20, output: 10)),
        "claude-sonnet-4-6": .init(standard: .init(input: 3, write5m: 3.75, write1h: 6, read: 0.30, output: 15)),
        "claude-haiku-5-5": .init(standard: .init(input: 0.10, write5m: 0.125, write1h: 0.20, read: 0.01, output: 0.50),
                                  longPrompt: .init(input: 0.50, write5m: 0.625, write1h: 1, read: 0.05, output: 2.50)),
        "claude-haiku-4-5-20251001": .init(standard: .init(input: 1, write5m: 1.25, write1h: 2, read: 0.10, output: 5),
                                           supportsUSGeography: false),
    ]
    static let longPromptThreshold: Int64 = 100_000

    /// Exact model matching; nil leaves the response unpriced rather than guessed.
    static func cost(_ counts: ClaudeTokenCounts, key: ClaudePricingKey) -> Double? {
        guard let model = models[key.model], key.speed == nil || key.speed == "standard",
              key.serviceTier == nil || key.serviceTier == "standard" else { return nil }
        let multiplier: Double
        switch key.inferenceGeo {
        case nil, "global": multiplier = 1
        case "us" where model.supportsUSGeography: multiplier = 1.1
        default: return nil
        }
        let rate = counts.prompt > longPromptThreshold ? model.longPrompt ?? model.standard : model.standard
        let base = Double(counts.input) * rate.input + Double(counts.cacheWrite5m) * rate.write5m
            + Double(counts.cacheWrite1h) * rate.write1h + Double(counts.cacheRead) * rate.read + Double(counts.output) * rate.output
        return base * multiplier / 1_000_000
    }
}
