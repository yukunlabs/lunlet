// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-31, AC-31.01, AC-31.02, AC-31.04; US-04, AC-04.04; US-19, AC-19.01; US-21, AC-21.04, AC-21.05.
// Refs: US-40, AC-40.01; US-24, AC-24.01, AC-24.02; US-33, AC-33.08; US-38, AC-38.06.
import Foundation

/// What Settings shows, apart from how it is drawn: its tabs, the options of the selected entry, where the figures
/// come from and the rule that one agent stays on. Presentation only: no setting is defined or changed here.
enum SettingsModel {
    /// The categories in the confirmed order, Appearance first (AC-31.04).
    static let tabs = PreferenceCategory.allCases
    /// Appearance, unless a page asked for a category such as Agents.
    static func opening(_ requested: PreferenceCategory?) -> PreferenceCategory { requested ?? .appearance }
    static func tabLabel(_ category: PreferenceCategory) -> String { category.rawValue + " settings" }
    /// The tab an arrow key selects; the ends do not wrap, as in the panel's segmented controls.
    static func neighbor(of category: PreferenceCategory, offset: Int) -> PreferenceCategory? {
        guard let index = tabs.firstIndex(of: category), tabs.indices.contains(index + offset) else { return nil }
        return tabs[index + offset]
    }

    /// The three pictured entries.
    static let entries = EntryPresentation.allCases
    enum EntryOption: Equatable { case showAllowance, onlyBelow, pet, coat, packs }
    /// The rows under the entry choice: only the selected entry's own options (AC-21.04, AC-21.05, AC-40.01). A
    /// chosen pack brings its own colors, so the coat is offered for the built-in dog only.
    static func entryOptions(_ value: LunletPreferences, packsListed: Bool) -> [EntryOption] {
        switch value.presentation {
        case .notch: return []
        case .menuBar: return value.menuBarAllowance == .off ? [.showAllowance] : [.showAllowance, .onlyBelow]
        case .pet:
            guard packsListed else { return [.coat] }
            return value.petPack == nil ? [.pet, .coat, .packs] : [.pet, .packs]
        }
    }
    /// One line under the entry choice saying what the selected entry is.
    static func entryNote(_ presentation: EntryPresentation) -> String {
        switch presentation {
        case .notch: "Sits on both sides of the notch on a built-in display."
        case .menuBar: "A standard menu bar item. The text shows the window closest to running out."
        case .pet: "A small dog on every Space that shows what your agents are doing."
        }
    }
    static let entryHelp = "The notch widget flanks a hardware notch; the menu bar entry is a standard status item; the desktop "
        + "pet is a small dog on every Space that shows what your agents are doing and opens the panel beside it."

    struct Source: Equatable {
        let label: String
        let value: String
        let help: String?
    }
    /// Where each figure comes from, for the agents shown: source, purpose and destination in a few words, with the
    /// credential handling in help (AC-04.04).
    static func sources(providers: [AgentProvider]) -> [Source] {
        var rows: [Source] = []
        if providers.contains(.codex) {
            rows.append(.init(label: "Codex limits", value: "Your local Codex sign-in · OpenAI account",
                              help: "Account identity and limits are read automatically through Codex. Sign-in credentials are "
                                + "never sent through messaging channels. Quitting cancels owned reads."))
        }
        if providers.contains(.claude) {
            rows.append(.init(label: "Claude Code limits", value: "Claude Code's status line",
                              help: "Claude Code reports percent used and reset times through the status line Lunlet adds "
                                + "while Claude Code is selected. Lunlet keeps only those and reads no credentials."))
        }
        rows.append(.init(label: "Tokens and cost", value: "Recorded on this Mac · API list prices",
                          help: "Token counts come from each agent's local usage records on this Mac. Cost is an estimate "
                            + "at published API list prices, not a bill."))
        return rows
    }

    /// One line under an agent's switch saying what showing it reads or changes; the full account is in its help.
    static func agentDetail(_ agent: AgentProvider) -> String {
        switch agent {
        case .codex: "Sessions, limits and usage through your local Codex sign-in."
        case .claude:
            "Local sessions and usage. Adds a status line and a Stop hook to Claude Code's settings; both are removed "
                + "when you turn it off."
        }
    }
    /// The last selected agent cannot be turned off (AC-19.01, AC-19.02).
    static func canTurnOff(_ agent: AgentProvider, selected: [AgentProvider]) -> Bool { selected != [agent] }
    /// The selection after an agent's switch moved; a newly shown agent appends, so earlier ones keep their place.
    static func toggled(_ agent: AgentProvider, on: Bool, in selected: [AgentProvider]) -> [AgentProvider] {
        if on { return selected.contains(agent) ? selected : selected + [agent] }
        return selected.filter { $0 != agent }
    }
}

/// A connection's state as Settings words it: the text, its tone and the one action it may need. The words carry
/// the state; the tone only colors them (AC-24.02).
struct SettingsStatus: Equatable {
    enum Action: Equatable { case forget, retry }
    let text: String
    let tone: PanelTone
    let action: Action?
    /// A state that needs the owner reads as a note with its action; a healthy one is a single status word.
    var needsAttention: Bool { tone == .attention }
}
