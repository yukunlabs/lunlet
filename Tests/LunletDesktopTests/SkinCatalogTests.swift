// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01, AC-16.02.
// Refs: US-17, AC-17.01, AC-17.02, AC-17.03, AC-17.04, AC-17.05, AC-17.07, AC-17.08; US-26, AC-26.02.
import AppKit
import Foundation
import Testing
@testable import LunletDesktop

struct SkinCatalogTests {
    @Test @MainActor func everyOfficialCatalogSkinAcceptsTheSavedPalette() {
        let vine = SkinCatalog.builtins[0], lantern = SkinCatalog.builtins[1]
        #expect(vine.allowsColorEditing)
        #expect(vine.resolvedAccent(override: "#AA66DD") == "#AA66DD")
        #expect(lantern.allowsColorEditing)
        #expect(lantern.resolvedAccent(override: "#AA66DD") == "#AA66DD")
        for skin in SkinCatalog.builtins {
            #expect(skin.allowsColorEditing)
            #expect(skin.resolvedAccent(override: "#AA66DD") == "#AA66DD")
        }
        var custom = SkinDefinition(id: "aurora", title: "Aurora", kind: .vine)
        custom.accentHex = "#88AAEE"
        #expect(!custom.allowsColorEditing)
        #expect(custom.resolvedAccent(override: "#AA66DD") == "#88AAEE")
        custom.accentHex = nil
        #expect(custom.resolvedAccent(override: "#AA66DD") == nil)
        custom.kind = .lantern; custom.accentHex = "#BB4455"
        #expect(custom.resolvedAccent(override: "#AA66DD") == "#BB4455")
        #expect(vine.resolvedAccent(override: "#AA66DD") == "#AA66DD")
    }

    // AC-16.02, AC-17.08: the panel tint, color well and artwork share one resolution.
    @Test @MainActor func everyAccentConsumerResolvesTheSkinAndItsDrawnFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-accent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SkinCatalog(directory: root)
        var preferences = LunletPreferences()
        #expect(catalog.accentHex(for: preferences) == nil)
        #expect(catalog.displayedAccentHex(for: preferences) == "#B7AFE5")
        #expect(LettermarkView.defaultVinePearl[2] == SkinKind.vine.fallbackAccent)
        // The pale drawn pearl is not a control tint; default vine controls keep a deeper shade.
        #expect(catalog.controlTint(for: preferences) == AllowanceColor(hex: 0x856bc7))
        preferences.skinID = "lantern"
        #expect(catalog.displayedAccentHex(for: preferences) == "#C83F49")
        #expect(catalog.controlTint(for: preferences) == SkinKind.lantern.fallbackAccent)
        preferences.accentHex = "#AA66DD"
        #expect(catalog.displayedAccentHex(for: preferences) == "#AA66DD")
        #expect(catalog.controlTint(for: preferences) == AllowanceColor(hexString: "#AA66DD"))
        // An imported skin owns its color: the owner's saved override no longer tints the panel.
        let aurora = ##"{"schemaVersion":1,"id":"aurora","title":"Aurora","kind":"vine","accentHex":"#88AAEE"}"##
        _ = try catalog.install(Data(aurora.utf8))
        preferences.skinID = "aurora"
        #expect(catalog.accentHex(for: preferences) == "#88AAEE")
        #expect(catalog.displayedAccentHex(for: preferences) == "#88AAEE")
        _ = try catalog.install(Data(#"{"schemaVersion":1,"id":"dusk","title":"Dusk","kind":"lantern"}"#.utf8))
        preferences.skinID = "dusk"
        #expect(catalog.accentHex(for: preferences) == nil)
        #expect(catalog.displayedAccentHex(for: preferences) == SkinKind.lantern.fallbackAccentHex)
        #expect(SkinCatalog.accentHex(for: preferences, in: catalog.skins) == catalog.accentHex(for: preferences))
    }

    @Test func fiveLanternsRepresentTwentyPercentEachAndUnknownIsDistinctFromZero() {
        #expect(LanternLevels.values(remaining: 100) == [1, 1, 1, 1, 1])
        #expect(LanternLevels.values(remaining: 70) == [1, 1, 1, 0.5, 0])
        #expect(LanternLevels.values(remaining: 10) == [0.5, 0, 0, 0, 0])
        #expect(LanternLevels.values(remaining: 0) == [0, 0, 0, 0, 0])
        #expect(LanternLevels.values(remaining: nil) == nil)
        #expect(LanternLevels.values(remaining: .nan) == nil)
    }

    @Test @MainActor func validatedUserSkinCanBeImportedReopenedAndSelectedWithoutSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-skins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SkinCatalog(directory: root)
        #expect(catalog.skins.map(\.id) == ["vine", "lantern"])
        let data = Data(##"{"schemaVersion":1,"id":"aurora","title":"Aurora","kind":"vine","accentHex":"#88AAEE","strokeWidth":3,"leftWord":"M1 2 L20 20","rightWord":"M2 3 C4 5 6 7 8 9"}"##.utf8)
        let imported = try catalog.install(data)
        #expect(imported.id == "aurora" && imported.strokeWidth == 3)
        let reopened = SkinCatalog(directory: root)
        #expect(reopened.skin(id: "aurora").accentHex == "#88AAEE")
        #expect(reopened.skin(id: "missing").id == "vine")
    }

    @Test @MainActor func invalidPackagesCannotOverwriteBuiltinsEscapeTheirDirectoryOrReachThePathRenderer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-skins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SkinCatalog(directory: root)
        for fragment in [#""id":"../escape""#, #""id":"vine""#, #""schemaVersion":99"#,
                         #""leftWord":"M1""#, #""leftWord":"M0 0 C1 2""#,
                         #""leftWord":"M0 0 L999999 1""#, #""leftWord":"M0 0 LNaN 1""#,
                         #""leftWord":"M0 0 L1e999 1""#, #""script":"open credentials""#,
                         #""bodyPath":"M0 40 L10 40 M263 40 L273 40""#] {
            var object: [String: Any] = ["schemaVersion": 1, "id": "custom", "title": "Custom", "kind": "vine"]
            let overrides = try #require(JSONSerialization.jsonObject(with: Data(("{" + fragment + "}").utf8)) as? [String: Any])
            object.merge(overrides) { _, next in next }
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try catalog.install(data) }
        }
        #expect(catalog.skins.count == 2)

    }
    @Test @MainActor func lanternTintChangesBothLampsAndLetteringWithoutChangingAllowance() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setSkin(SkinCatalog.builtins[1]); view.setAllowance(70); view.layoutSubtreeIfNeeded()
        let lamps = try #require(view.layer?.sublayers?.first { $0.name == "lanterns" })
        let lamp = try #require(lamps.sublayers?.first { $0.name == "lamp-0" })
        let oldShadow = try #require(lamp.shadowColor)
        let letters = try #require(view.layer?.sublayers?.first { $0.name == "lun" })
        let before = try #require((letters.sublayers?.first as? CAGradientLayer)?.colors as? [CGColor])
        view.setAccent("#4477CC"); view.layoutSubtreeIfNeeded()
        let changedLamp = try #require(lamps.sublayers?.first { $0.name == "lamp-0" })
        #expect(changedLamp.shadowColor != oldShadow)
        #expect(changedLamp.shadowColor == AllowanceColor(hex: 0x4477CC).cgColor)
        let after = try #require((letters.sublayers?.first as? CAGradientLayer)?.colors as? [CGColor])
        #expect(before != after)
        #expect(lamps.sublayers?.filter { $0.name?.hasPrefix("lamp-") == true }.count == 5)
    }

    @Test @MainActor func lanternSkinReplacesTheOuterVineAndHidesWithDetails() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setSkin(SkinCatalog.builtins[1]); view.setAllowance(70); view.layoutSubtreeIfNeeded()
        let lanterns = try #require(view.layer?.sublayers?.first { $0.name == "lanterns" })
        #expect(!lanterns.isHidden)
        #expect(lanterns.sublayers?.filter { $0.name?.hasPrefix("lamp-") == true }.count == 5)
        view.setDetailsVisible(true)
        #expect(lanterns.isHidden)
        view.setDetailsVisible(false); view.setSkin(SkinCatalog.builtins[0]); view.layoutSubtreeIfNeeded()
        #expect(lanterns.isHidden)
    }

}
