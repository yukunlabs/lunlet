// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01, AC-16.02; US-17, AC-17.08.
import AppKit
import Testing
@testable import LunletDesktop

@MainActor struct SkinColorControlsTests {
    @Test func redEndpointSurvivesRGBRoundTripAndCanMoveBackward() {
        var editing = HueEditingState()
        let red = editing.choose(1, from: NSColor(hue: 0.7, saturation: 0.6, brightness: 0.8, alpha: 1))
        editing.synchronize(NSColor(srgbRed: (red.redComponent * 255).rounded() / 255,
                                    green: (red.greenComponent * 255).rounded() / 255,
                                    blue: (red.blueComponent * 255).rounded() / 255, alpha: 1))
        #expect(editing.hue == 1)
        let previous = editing.choose(editing.hue - 0.01, from: red)
        #expect(abs(Double(previous.hueComponent) - 0.99) < 0.001)
    }

    @Test func spectrumCanColorNeutralShadesAndRetainsExistingColorDepth() {
        for color in [NSColor.white, NSColor.gray, NSColor.black] {
            var editing = HueEditingState()
            let selected = editing.choose(0.42, from: color)
            #expect(selected.saturationComponent > 0)
            #expect(selected.brightnessComponent > 0)
            #expect(abs(Double(selected.hueComponent) - 0.42) < 0.001)
        }
        var editing = HueEditingState()
        let selected = editing.choose(0.21, from: NSColor(hue: 0.6, saturation: 0.3, brightness: 0.4, alpha: 1))
        #expect(abs(Double(selected.saturationComponent) - 0.3) < 0.001)
        #expect(abs(Double(selected.brightnessComponent) - 0.4) < 0.001)
        editing.synchronize(NSColor(hue: 0.8, saturation: 0.7, brightness: 0.9, alpha: 1))
        #expect(abs(editing.hue - 0.8) < 0.001)
    }
}
