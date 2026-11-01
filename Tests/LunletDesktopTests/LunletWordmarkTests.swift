// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-21, AC-21.02.
import AppKit
import Testing
@testable import LunletDesktop

@MainActor struct LunletWordmarkTests {
    // The menu-bar entry is a monochrome lun·let template image, never the full-color app icon.
    @Test func menuBarEntryUsesATemplateWordmarkSizedForTheMenuBar() throws {
        let image = LunletWordmark.image()
        #expect(image.isTemplate)
        #expect(image.size.height == LunletWordmark.menuBarHeight && LunletWordmark.menuBarHeight <= 13)
        #expect((28...46).contains(image.size.width))
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var inked = 0, colored = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { continue }
            inked += 1
            if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.05 { colored += 1 }
        } }
        #expect(inked > 40 && colored == 0)
    }
}
