// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01; US-17, AC-17.08; US-18, AC-18.01; US-19, AC-19.01; US-20, AC-20.01;
// Refs: US-21, AC-21.01, AC-21.04, AC-21.05; US-26, AC-26.01, AC-26.02; US-31, AC-31.01.
// Refs: US-13, AC-13.11; US-41, AC-41.01, AC-41.02; US-33, AC-33.08; US-38, AC-38.06.
import Foundation
import Testing
@testable import LunletDesktop

@MainActor struct PreferencesStoreTests {
    @Test func preferencesSurviveReopeningAndKeepProviderChannelAndAppearanceChoices() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        var value = store.value
        value.historyDays = 7; value.presentation = .menuBar; value.skinID = "lantern"
        value.accentHex = "#A89BE8"; value.providers = [.codex, .claude]; value.channel = .telegram
        // AC-21.04, AC-21.05, AC-13.11, AC-41.01, AC-41.02: the entry text, the sound and the notification choices survive too.
        value.menuBarAllowance = .percentAndReset; value.menuBarAllowanceBelow = 30; value.needsYouSound = true
        value.allowanceNotifications = true; value.allowanceWarnBelow = 10; value.allowanceResetNotices = true
        try store.apply(value)
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.value == value)
        #expect(reopened.issue == nil)
    }

    // AC-33.08, AC-38.06: the Claude Code switch's own help says what selecting it adds to Claude Code's settings.
    @Test func theClaudeCodeSwitchExplainsItsStatusLineAndStopHook() throws {
        let help = try #require(AgentProvider.claude.switchHelp)
        #expect(help.contains("status line") && help.contains("footer keyboard hints"))
        #expect(help.contains("Stop hook for phone replies") && help.contains("removes both when it is turned off"))
        // Codex is observed without any change to its configuration, so its switch has nothing to disclose.
        #expect(AgentProvider.codex.switchHelp == nil)
    }

    // AC-17.08: each official skin keeps its own color and Restore resets only the selected one.
    @Test func officialSkinsKeepIndependentColorsAcrossSwitchesAndReopening() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        store.update { $0.skinID = "vine"; $0.accentHex = "#D0A8E6" }
        store.update { $0.skinID = "lantern" }
        #expect(store.value.accentHex == nil)
        store.update { $0.accentHex = "#AA3344" }
        store.update { $0.skinID = "vine" }
        #expect(store.value.accentHex == "#D0A8E6")
        store.update { $0.accentHex = nil }
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.value.accentHex == nil && reopened.value.accentOverrides == ["lantern": "#AA3344"])
    }
    @Test func aColorSavedInTheSharedFormatStaysWithTheSkinSelectedAtThatTime() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(##"{"schemaVersion":1,"skinID":"vine","accentHex":"#D0A8E6"}"##.utf8), forKey: "preferences.current")
        let store = PreferencesStore(defaults: defaults)
        #expect(store.issue == nil && store.value.accentOverrides == ["vine": "#D0A8E6"])
        store.update { $0.skinID = "lantern" }
        #expect(store.value.accentHex == nil)
    }

    @Test func invalidSavedConfigurationsRecoverThePreviousValidSelection() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        var valid = store.value; valid.historyDays = 3
        try store.apply(valid)
        var current = valid; current.historyDays = 6
        try store.apply(current)
        for data in [Data("not-json".utf8), Data(#"{"schemaVersion":99}"#.utf8),
                     Data(#"{"schemaVersion":1,"historyDays":0}"#.utf8),
                     Data(#"{"schemaVersion":1,"historyDays":8}"#.utf8),
                     Data(#"{"schemaVersion":1,"accentHex":"script()"}"#.utf8),
                     Data(#"{"schemaVersion":1,"accentOverrides":{"vine":"script()"}}"#.utf8),
                     Data(##"{"schemaVersion":1,"accentOverrides":{"../outside":"#112233"}}"##.utf8),
                     Data(#"{"schemaVersion":1,"skinID":"../../outside"}"#.utf8),
                     // The catalog never accepts a dotted identifier, so a saved choice cannot name one.
                     Data(#"{"schemaVersion":1,"skinID":"custom.skin"}"#.utf8),
                     Data(#"{"schemaVersion":1,"providers":[]}"#.utf8),
                     // AC-21.05 and AC-41.02 offer fixed levels; a saved level outside them is not a choice.
                     Data(#"{"schemaVersion":1,"menuBarAllowanceBelow":25}"#.utf8),
                     Data(#"{"schemaVersion":1,"allowanceWarnBelow":50}"#.utf8)] {
            defaults.set(data, forKey: "preferences.current")
            let recovered = PreferencesStore(defaults: defaults)
            #expect(recovered.value == valid)
            #expect(recovered.issue != nil)
        }
    }

    // AC-26.01: a newer build of the same schema adds fields; an older build opening its settings reads every field
    // it knows, reports nothing, and writes the newer build's fields back unchanged.
    @Test func fieldsSavedByANewerBuildAreCarriedThroughNotRejected() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        // Both saved copies carry fields this build does not know.
        let newer = ##"{"schemaVersion":1,"historyDays":3,"providers":["codex","claude"],"skinID":"lantern","futureSwitch":true,"futureCount":9007199254740993,"futureLayout":{"columns":[1,2,3],"name":"wide","ratio":1.5,"note":null}}"##
        let older = ##"{"schemaVersion":1,"historyDays":2,"providers":["claude"],"futureSwitch":false}"##
        defaults.set(Data(newer.utf8), forKey: "preferences.current")
        defaults.set(Data(older.utf8), forKey: "preferences.previous")
        let store = PreferencesStore(defaults: defaults)
        #expect(store.issue == nil)
        #expect(store.value.historyDays == 3 && store.value.providers == [.codex, .claude] && store.value.skinID == "lantern")
        func saved(_ key: String) throws -> [String: Any] {
            let data = try #require(defaults.data(forKey: key))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        store.update { $0.historyDays = 4 }
        #expect(store.issue == nil)
        let current = try saved("preferences.current")
        #expect(current["historyDays"] as? Int == 4 && current["futureSwitch"] as? Bool == true)
        #expect((current["futureCount"] as? NSNumber)?.int64Value == 9_007_199_254_740_993)
        let layout = try #require(current["futureLayout"] as? [String: Any])
        #expect(layout["columns"] as? [Int] == [1, 2, 3] && layout["name"] as? String == "wide")
        #expect(layout["ratio"] as? Double == 1.5 && layout["note"] is NSNull)
        // The copy kept as previous is the value that was current, with its fields.
        let previous = try saved("preferences.previous")
        #expect(previous["historyDays"] as? Int == 3 && previous["futureSwitch"] as? Bool == true)
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.issue == nil && reopened.value == store.value)
        // When the current copy is unreadable, the previous one is used with the fields it carried.
        defaults.set(Data("not-json".utf8), forKey: "preferences.current")
        let recovered = PreferencesStore(defaults: defaults)
        #expect(recovered.issue != nil && recovered.value.historyDays == 3)
        recovered.update { $0.historyDays = 5 }
        #expect(try saved("preferences.current")["futureSwitch"] as? Bool == true)
    }

    // AC-26.02: a value this build cannot read is never replaced without a copy being kept, and settings from a
    // newer schema are named as such.
    @Test func anUnreadableSavedValueIsKeptWhenItIsReplaced() throws {
        let (defaults, suite) = try ScratchSettings.make("preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let newer = Data(##"{"schemaVersion":2,"historyDays":"three days","layout":"new"}"##.utf8)
        defaults.set(newer, forKey: "preferences.current")
        defaults.set(newer, forKey: "preferences.previous")
        let store = PreferencesStore(defaults: defaults)
        #expect(store.value == LunletPreferences())
        #expect(store.issue?.contains("newer version of Lunlet") == true)
        // Opening writes nothing.
        #expect(defaults.data(forKey: "preferences.current") == newer && defaults.data(forKey: "preferences.unreadable") == nil)
        // An invalid change writes nothing either.
        store.update { $0.historyDays = 0 }
        #expect(defaults.data(forKey: "preferences.current") == newer && defaults.data(forKey: "preferences.unreadable") == nil)
        store.update { $0.historyDays = 2 }
        #expect(defaults.data(forKey: "preferences.unreadable") == newer)
        #expect(PreferencesStore(defaults: defaults).value.historyDays == 2)
        // A corrupt value keeps the general message and is kept as well.
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "preferences.current")
        let recovered = PreferencesStore(defaults: defaults)
        #expect(recovered.issue?.contains("could not be read") == true && recovered.issue?.contains("newer version") == false)
        recovered.update { $0.historyDays = 6 }
        #expect(defaults.data(forKey: "preferences.unreadable") == corrupt)
        #expect(PreferencesStore(defaults: defaults).value.historyDays == 6)
    }
}
