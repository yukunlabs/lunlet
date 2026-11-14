// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01; US-17, AC-17.08; US-18, AC-18.01; US-19, AC-19.01; US-20, AC-20.01;
// Refs: US-21, AC-21.01, AC-21.04, AC-21.05; US-26, AC-26.01, AC-26.02; US-31, AC-31.01; US-33, AC-33.01; US-40, AC-40.01.
// Refs: US-13, AC-13.11; US-41, AC-41.01, AC-41.02.
import Combine
import Foundation
import LunletCore

enum EntryPresentation: String, Codable, CaseIterable {
    case notch, menuBar, pet
    var title: String {
        switch self { case .notch: "Notch widget"; case .menuBar: "Menu bar"; case .pet: "Desktop pet" }
    }
}
/// What the menu-bar entry shows beside the lettering (AC-21.04).
enum MenuBarAllowance: String, Codable, CaseIterable {
    case off, percent, percentAndReset
    var title: String {
        switch self { case .off: "Off"; case .percent: "Percent"; case .percentAndReset: "Percent and reset" }
    }
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
    /// What selecting the agent changes outside Lunlet, for its switch's help (AC-33.08, AC-38.06).
    var switchHelp: String? {
        switch self {
        case .codex: nil
        case .claude:
            "Claude Code is observed from its own local session records and transcripts, without sockets. "
                + "While it is selected, Lunlet adds two things to Claude Code's user settings and removes both when it is "
                + "turned off: a status line for plan limits (a custom status line hides most footer keyboard hints; any "
                + "existing one keeps running and is restored exactly) and a Stop hook for phone replies, which keeps a "
                + "finished turn open for one reply only while this Mac is locked. Only the account email and plan are kept "
                + "from Claude Code's profile; credentials and environment values are never read."
        }
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

/// One JSON value of a field this build does not know, saved by a newer one. It is written back as it was read
/// and never interpreted (AC-26.01).
enum UnknownPreferenceValue: Codable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([UnknownPreferenceValue]), object([String: UnknownPreferenceValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([UnknownPreferenceValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: UnknownPreferenceValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

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

    /// Where the pet sits on one display (AC-39.02): with `relative` true, the window origin's offset from the corner
    /// of that display's visible area, which a change of the display arrangement leaves valid; without it, a place
    /// an earlier build saved as an origin in global screen coordinates.
    struct PetPosition: Codable, Equatable { var x: Double; var y: Double; var relative: Bool? }
    var petCoat: PetCoat = .golden
    /// Keyed by display number, so each display keeps its own place.
    var petPositions: [String: PetPosition] = [:]
    /// The display number the pet was last placed on, so a relaunch brings it back there while it is connected.
    var petDisplay: String?
    /// The chosen pet pack as `source/folder` (AC-40.01); nil is the built-in dog.
    var petPack: String?
    /// The allowance text in the menu-bar entry (AC-21.04) and the percent left below which it shows; nil shows it always (AC-21.05).
    var menuBarAllowance = MenuBarAllowance.off
    var menuBarAllowanceBelow: Int?
    static let menuBarAllowanceLevels = [50, 30, 20]
    /// One system sound with each Needs you cue (AC-13.11).
    var needsYouSound = false
    /// Allowance notifications: the switch, the percent left that warns and the reset notice (AC-41.01, AC-41.02).
    var allowanceNotifications = false
    var allowanceWarnBelow = 20
    var allowanceResetNotices = false
    static let allowanceWarnLevels = [30, 20, 10, 5]
    /// When the notch entry steps aside for another application's full-screen window (AC-42.03).
    var fullScreen = FullScreenPolicy.video
    /// Fields a newer build of this schema saved and this build does not know. They travel with the value and are
    /// written back unchanged, so opening newer settings here never strips them (AC-26.01).
    private(set) var unknownFields: [String: UnknownPreferenceValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, presentation, skinID, accentOverrides, accentHex, historyDays, providers, channel, petCoat, petPositions, petDisplay,
             petPack, menuBarAllowance, menuBarAllowanceBelow, needsYouSound, allowanceNotifications, allowanceWarnBelow, allowanceResetNotices,
             fullScreen
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init() {}
    init(from decoder: any Decoder) throws {
        let every = try decoder.container(keyedBy: AnyKey.self)
        for key in every.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
            unknownFields[key.stringValue] = try every.decode(UnknownPreferenceValue.self, forKey: key)
        }
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
        petCoat = try data.decodeIfPresent(PetCoat.self, forKey: .petCoat) ?? .golden
        petPositions = try data.decodeIfPresent([String: PetPosition].self, forKey: .petPositions) ?? [:]
        petDisplay = try data.decodeIfPresent(String.self, forKey: .petDisplay)
        petPack = try data.decodeIfPresent(String.self, forKey: .petPack)
        menuBarAllowance = try data.decodeIfPresent(MenuBarAllowance.self, forKey: .menuBarAllowance) ?? .off
        menuBarAllowanceBelow = try data.decodeIfPresent(Int.self, forKey: .menuBarAllowanceBelow)
        needsYouSound = try data.decodeIfPresent(Bool.self, forKey: .needsYouSound) ?? false
        allowanceNotifications = try data.decodeIfPresent(Bool.self, forKey: .allowanceNotifications) ?? false
        allowanceWarnBelow = try data.decodeIfPresent(Int.self, forKey: .allowanceWarnBelow) ?? 20
        allowanceResetNotices = try data.decodeIfPresent(Bool.self, forKey: .allowanceResetNotices) ?? false
        // A choice a later build adds reads as the default here, and the settings stay readable.
        fullScreen = (try data.decodeIfPresent(String.self, forKey: .fullScreen)).flatMap(FullScreenPolicy.init(rawValue:)) ?? .video
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
        try data.encode(petCoat, forKey: .petCoat)
        if !petPositions.isEmpty { try data.encode(petPositions, forKey: .petPositions) }
        try data.encodeIfPresent(petDisplay, forKey: .petDisplay)
        try data.encodeIfPresent(petPack, forKey: .petPack)
        try data.encode(menuBarAllowance, forKey: .menuBarAllowance)
        try data.encodeIfPresent(menuBarAllowanceBelow, forKey: .menuBarAllowanceBelow)
        try data.encode(needsYouSound, forKey: .needsYouSound)
        try data.encode(allowanceNotifications, forKey: .allowanceNotifications)
        try data.encode(allowanceWarnBelow, forKey: .allowanceWarnBelow)
        try data.encode(allowanceResetNotices, forKey: .allowanceResetNotices)
        try data.encode(fullScreen, forKey: .fullScreen)
        var every = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in unknownFields where CodingKeys(stringValue: name) == nil {
            try every.encode(value, forKey: AnyKey(stringValue: name))
        }
    }
    func validate() throws {
        // Same identifier rule as SkinDefinition.validate, so a saved choice can name a real skin.
        let skinIDRule = "^[a-z0-9][a-z0-9_-]{0,63}$"
        guard schemaVersion == 1 else { throw PreferenceFailure.unsupportedVersion }
        guard accentOverrides.count <= 16, accentOverrides.allSatisfy({
            $0.key.range(of: skinIDRule, options: .regularExpression) != nil
                && $0.value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        }) else { throw PreferenceFailure.invalidValue }
        guard petPositions.count <= 16, petPositions.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw PreferenceFailure.invalidValue
        }
        if let petDisplay { guard !petDisplay.isEmpty, petDisplay.count <= 32 else { throw PreferenceFailure.invalidValue } }
        if let petPack { guard PetPackReference(key: petPack) != nil else { throw PreferenceFailure.invalidValue } }
        if let level = menuBarAllowanceBelow { guard Self.menuBarAllowanceLevels.contains(level) else { throw PreferenceFailure.invalidValue } }
        guard Self.allowanceWarnLevels.contains(allowanceWarnBelow) else { throw PreferenceFailure.invalidValue }
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
    /// The saved value this build could not read, such as a newer schema's. It stays where it is until a setting
    /// changes, and is then kept under its own key instead of being lost (AC-26.02).
    private var unreadable: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let current = defaults.data(forKey: "preferences.current") {
            do { value = try Self.decode(current) }
            catch {
                value = defaults.data(forKey: "preferences.previous").flatMap { try? Self.decode($0) } ?? .init()
                unreadable = current
                if case PreferenceFailure.unsupportedVersion = error {
                    issue = "These settings were saved by a newer version of Lunlet, which this version cannot read. "
                        + "They are kept; the previous valid settings or defaults are in use."
                } else {
                    issue = "Saved settings could not be read. The previous valid settings or defaults are in use."
                }
            }
        } else { value = .init() }
    }

    func apply(_ next: LunletPreferences) throws {
        try next.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let previous = try encoder.encode(value)
        if let unreadable { defaults.set(unreadable, forKey: "preferences.unreadable"); self.unreadable = nil }
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
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PreferenceFailure.invalidValue }
        // A newer schema is named before any of its fields is read, whatever shape they have. Fields this schema
        // does not know are carried through by the value itself, never rejected.
        if let version = object["schemaVersion"] as? Int, version > 1 { throw PreferenceFailure.unsupportedVersion }
        do { return try JSONDecoder().decode(LunletPreferences.self, from: data) }
        // Only a later schema is "newer"; any other version number is simply not a saved value of this app.
        catch PreferenceFailure.unsupportedVersion { throw PreferenceFailure.invalidValue }
    }
}

extension LunletPreferences {
    /// Selected providers that have an implementation, in their saved order.
    var sessionProviders: [SessionProvider] {
        var seen: Set<SessionProvider> = []
        return providers.map(\.sessionProvider).filter { seen.insert($0).inserted }
    }
}
