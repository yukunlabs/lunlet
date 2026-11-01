// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01; US-17, AC-17.08; US-18, AC-18.01; US-19, AC-19.01; US-20, AC-20.01;
// Refs: US-21, AC-21.01; US-26, AC-26.01, AC-26.02; US-31, AC-31.01; US-33, AC-33.01.
import Combine
import Foundation
import LunletCore

enum EntryPresentation: String, Codable, CaseIterable {
    case notch, menuBar
    var title: String { self == .notch ? "Notch widget" : "Menu bar" }
}
enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    /// Only implemented providers are offered; a later agent is added here once its own gates are satisfied.
    var sessionProvider: SessionProvider {
        switch self { case .codex: .codex; case .claude: .claude }
    }
    var title: String {
        switch self { case .codex: "Codex"; case .claude: "Claude Code" }
    }
}
enum CommunicationChannel: String, Codable, CaseIterable, Identifiable {
    case feishu, slack, telegram
    var id: String { rawValue }
    var title: String {
        switch self { case .feishu: "Feishu / Lark"; case .slack: "Slack"; case .telegram: "Telegram" }
    }
}
enum PreferenceFailure: Error { case unsupportedVersion, invalidValue, oversized }

/// Only non-secret preferences belong here. Importing this value cannot authorize
/// a provider, install executable code, or grant access to credentials.
struct LunletPreferences: Codable, Equatable {
    var schemaVersion = 1
    var presentation = EntryPresentation.notch
    var skinID = "vine"
    /// Each official skin keeps its own color; a skin never customized draws its default.
    var accentOverrides: [String: String] = [:]
    /// The selected skin's saved color.
    var accentHex: String? {
        get { accentOverrides[skinID] }
        set { accentOverrides[skinID] = newValue }
    }
    var historyDays = 5
    var providers: [AgentProvider] = [.codex]
    var channel = CommunicationChannel.feishu

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, presentation, skinID, accentOverrides, accentHex, historyDays, providers, channel
    }
    init() {}
    init(from decoder: any Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try data.decode(Int.self, forKey: .schemaVersion)
        presentation = try data.decodeIfPresent(EntryPresentation.self, forKey: .presentation) ?? .notch
        skinID = try data.decodeIfPresent(String.self, forKey: .skinID) ?? "vine"
        accentOverrides = try data.decodeIfPresent([String: String].self, forKey: .accentOverrides) ?? [:]
        // The earlier shared color stays with the skin that was selected when it was saved.
        if accentOverrides.isEmpty, let legacy = try data.decodeIfPresent(String.self, forKey: .accentHex) {
            accentOverrides[skinID] = legacy
        }
        historyDays = try data.decodeIfPresent(Int.self, forKey: .historyDays) ?? 5
        providers = try data.decodeIfPresent([AgentProvider].self, forKey: .providers) ?? [.codex]
        let savedChannel = try data.decodeIfPresent(String.self, forKey: .channel) ?? "feishu"
        if savedChannel == "whatsapp" { channel = .feishu }
        else if let supported = CommunicationChannel(rawValue: savedChannel) { channel = supported }
        else { throw PreferenceFailure.invalidValue }
        try validate()
    }
    func encode(to encoder: any Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(schemaVersion, forKey: .schemaVersion); try data.encode(presentation, forKey: .presentation)
        try data.encode(skinID, forKey: .skinID); try data.encode(accentOverrides, forKey: .accentOverrides)
        try data.encode(historyDays, forKey: .historyDays); try data.encode(providers, forKey: .providers)
        try data.encode(channel, forKey: .channel)
    }
    func validate() throws {
        // Same identifier rule as SkinDefinition.validate, so a saved choice can name a real skin.
        let skinIDRule = "^[a-z0-9][a-z0-9_-]{0,63}$"
        guard schemaVersion == 1 else { throw PreferenceFailure.unsupportedVersion }
        guard accentOverrides.count <= 16, accentOverrides.allSatisfy({
            $0.key.range(of: skinIDRule, options: .regularExpression) != nil
                && $0.value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        }) else { throw PreferenceFailure.invalidValue }
        guard (1...7).contains(historyDays), !providers.isEmpty,
              Set(providers).count == providers.count,
              skinID.range(of: skinIDRule, options: .regularExpression) != nil else {
            throw PreferenceFailure.invalidValue
        }
    }
}

@MainActor final class PreferencesStore: ObservableObject {
    @Published private(set) var value: LunletPreferences
    @Published private(set) var issue: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let current = defaults.data(forKey: "preferences.current") {
            if let decoded = try? Self.decode(current) { value = decoded }
            else {
                value = defaults.data(forKey: "preferences.previous").flatMap { try? Self.decode($0) } ?? .init()
                issue = "Saved settings could not be read. The previous valid settings or defaults are in use."
            }
        } else { value = .init() }
    }

    func apply(_ next: LunletPreferences) throws {
        try next.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let previous = try encoder.encode(value)
        defaults.set(previous, forKey: "preferences.previous")
        defaults.set(data, forKey: "preferences.current")
        value = next; issue = nil
    }
    func update(_ change: (inout LunletPreferences) -> Void) {
        var next = value; change(&next)
        do { try apply(next) }
        catch { issue = "That setting is invalid. Your previous settings have been kept." }
    }
    private static func decode(_ data: Data) throws -> LunletPreferences {
        guard data.count <= 65_536 else { throw PreferenceFailure.oversized }
        let fields: Set<String> = ["schemaVersion", "presentation", "skinID", "accentOverrides", "accentHex", "historyDays",
                                   "providers", "channel"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: fields) else { throw PreferenceFailure.invalidValue }
        return try JSONDecoder().decode(LunletPreferences.self, from: data)
    }
}

extension LunletPreferences {
    /// Selected providers that have an implementation, in their saved order.
    var sessionProviders: [SessionProvider] {
        var seen: Set<SessionProvider> = []
        return providers.map(\.sessionProvider).filter { seen.insert($0).inserted }
    }
}
