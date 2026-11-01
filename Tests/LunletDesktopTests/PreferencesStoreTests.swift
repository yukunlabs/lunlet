// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01; US-17, AC-17.08; US-18, AC-18.01; US-19, AC-19.01; US-20, AC-20.01;
// Refs: US-21, AC-21.01; US-26, AC-26.01, AC-26.02; US-31, AC-31.01.
import Foundation
import Testing
@testable import LunletDesktop

@MainActor struct PreferencesStoreTests {
    @Test func preferencesSurviveReopeningAndKeepProviderChannelAndAppearanceChoices() throws {
        let suite = "com.lunlet.test.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        var value = store.value
        value.historyDays = 7; value.presentation = .menuBar; value.skinID = "lantern"
        value.accentHex = "#A89BE8"; value.providers = [.codex, .claude]; value.channel = .telegram
        try store.apply(value)
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.value == value)
        #expect(reopened.issue == nil)
    }

    // AC-17.08: each official skin keeps its own color and Restore resets only the selected one.
    @Test func officialSkinsKeepIndependentColorsAcrossSwitchesAndReopening() throws {
        let suite = "com.lunlet.test.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        let suite = "com.lunlet.test.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(##"{"schemaVersion":1,"skinID":"vine","accentHex":"#D0A8E6"}"##.utf8), forKey: "preferences.current")
        let store = PreferencesStore(defaults: defaults)
        #expect(store.issue == nil && store.value.accentOverrides == ["vine": "#D0A8E6"])
        store.update { $0.skinID = "lantern" }
        #expect(store.value.accentHex == nil)
    }

    @Test func invalidSavedConfigurationsRecoverThePreviousValidSelection() throws {
        let suite = "com.lunlet.test.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
                     Data(#"{"schemaVersion":1,"id":"wrong-file","kind":"vine"}"#.utf8)] {
            defaults.set(data, forKey: "preferences.current")
            let recovered = PreferencesStore(defaults: defaults)
            #expect(recovered.value == valid)
            #expect(recovered.issue != nil)
        }
    }
}
