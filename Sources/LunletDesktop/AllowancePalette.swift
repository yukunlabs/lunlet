// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01, AC-16.02, AC-16.03.
// Refs: US-04, AC-04.03, AC-04.07, AC-04.10; US-03, AC-03.07.
import AppKit
import LunletCore
import SwiftUI

struct AllowanceColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    init(hex: Int) {
        red = Double((hex >> 16) & 255) / 255
        green = Double((hex >> 8) & 255) / 255
        blue = Double(hex & 255) / 255
    }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init?(hexString: String) {
        guard hexString.count == 7, hexString.first == "#", let value = Int(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
    var hex: Int { (Int((red * 255).rounded()) << 16) | (Int((green * 255).rounded()) << 8) | Int((blue * 255).rounded()) }
    /// The same saturation and brightness a fraction of a turn around the hue circle; gray stays gray.
    func rotatingHue(by turn: Double) -> Self {
        let high = max(red, green, blue), low = min(red, green, blue), delta = high - low
        guard turn != 0, delta > 0 else { return self }
        var sector = high == red ? (green - blue) / delta : high == green ? (blue - red) / delta + 2 : (red - green) / delta + 4
        sector = ((sector / 6 + turn).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let whole = sector.rounded(.down), part = sector - whole, saturation = delta / high
        let p = high * (1 - saturation), q = high * (1 - saturation * part), t = high * (1 - saturation * (1 - part))
        switch Int(whole) % 6 {
        case 0: return .init(red: high, green: t, blue: p)
        case 1: return .init(red: q, green: high, blue: p)
        case 2: return .init(red: p, green: high, blue: t)
        case 3: return .init(red: p, green: q, blue: high)
        case 4: return .init(red: t, green: p, blue: high)
        default: return .init(red: high, green: p, blue: q)
        }
    }
    /// A clearly different sibling for a second agent: turned around the hue circle, away from the yellow and
    /// orange warning hues, then more saturated and deeper, so the pair differs in hue and in lightness. On the
    /// built-in palettes the pair is at least 25 CIEDE2000 apart; a 50-degree turn alone was about 12, too close.
    func agentVariant(turn: Double) -> Self {
        guard turn != 0 else { return self }
        let high = max(red, green, blue), saturation = high > 0 ? (high - min(red, green, blue)) / high : 0
        guard saturation > 0.02 else { return self }
        var turned = rotatingHue(by: turn)
        if (20.0...75.0).contains(turned.hue * 360) { turned = rotatingHue(by: -turn) }
        return turned.with(saturation: min(0.85, max(0.5, saturation * 1.7)), brightness: high * 0.78)
    }
    /// Hue as a fraction of a turn; gray reads zero.
    var hue: Double {
        let high = max(red, green, blue), delta = high - min(red, green, blue)
        guard delta > 0 else { return 0 }
        let sector = high == red ? (green - blue) / delta : high == green ? (blue - red) / delta + 2 : (red - green) / delta + 4
        return ((sector / 6).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
    }
    /// The same hue at a new saturation and brightness.
    func with(saturation: Double, brightness: Double) -> Self {
        let high = max(red, green, blue), low = min(red, green, blue)
        guard high > low else { return .init(red: brightness, green: brightness, blue: brightness) }
        // Rebuild from hue: scale each channel's position between low and high onto the new range.
        let newLow = brightness * (1 - saturation)
        func channel(_ value: Double) -> Double { newLow + (value - low) / (high - low) * (brightness - newLow) }
        return .init(red: channel(red), green: channel(green), blue: channel(blue))
    }
    func blended(toward other: Self, amount: Double) -> Self {
        .init(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
              blue: blue + (other.blue - blue) * amount)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var cgColor: CGColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor }
}

enum AllowancePalette {
    static let track = AllowanceColor(hex: 0xa28dc2)
    private static let stops: [(Double, [Int])] = [
        (0, [0xef919b, 0xe66b7d, 0xcb455e]), (10, [0xf4b49d, 0xee9683, 0xdd786e]),
        (18, [0xf3dfaa, 0xebcc82, 0xdbb35f]), (20, [0xb8d7f5, 0xbac0ef, 0xae92db]),
    ]
    static func normalized(_ remaining: Double?) -> Double? {
        guard let remaining, remaining.isFinite else { return nil }
        return min(100, max(0, remaining))
    }
    /// `hueShift` turns only the palette's own colors, so each agent keeps a variant while the low-allowance
    /// yellow and red stay the same for every agent.
    static func colors(remaining: Double?, tintHex: String? = nil, hueShift: Double = 0) -> [AllowanceColor] {
        guard let value = normalized(remaining) else { return Array(repeating: .init(hex: 0xaaa6ba), count: 3) }
        var stops = Self.stops
        if let tint = tintHex.flatMap(AllowanceColor.init(hexString:)) {
            stops[stops.count - 1].1 = [tint.blended(toward: .init(hex: 0xffffff), amount: 0.35).hex,
                                      tint.hex, tint.blended(toward: .init(hex: 0), amount: 0.12).hex]
        }
        stops[stops.count - 1].1 = stops[stops.count - 1].1.map { AllowanceColor(hex: $0).agentVariant(turn: hueShift).hex }
        let amount = min(20, value)
        let upper = stops.firstIndex { $0.0 >= amount } ?? (stops.count - 1)
        let high = stops[upper], low = stops[max(0, upper - 1)]
        let raw = high.0 == low.0 ? 1 : (amount - low.0) / (high.0 - low.0)
        let t = raw * raw * (3 - 2 * raw)
        return zip(low.1, high.1).map { a, b in
            let a = AllowanceColor(hex: a), b = AllowanceColor(hex: b)
            return .init(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                         blue: a.blue + (b.blue - a.blue) * t)
        }
    }
    static func trackColor(tintHex: String?, hueShift: Double = 0) -> AllowanceColor {
        (tintHex.flatMap(AllowanceColor.init(hexString:)) ?? track).agentVariant(turn: hueShift)
    }
    static func gradient(remaining: Double, tintHex: String? = nil, hueShift: Double = 0) -> LinearGradient {
        let colors = colors(remaining: remaining, tintHex: tintHex, hueShift: hueShift)
        return LinearGradient(stops: [.init(color: colors[0].color, location: 0),
            .init(color: colors[1].color, location: 0.4), .init(color: colors[2].color, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// One color identity per agent, everywhere it appears: the notch strand, meters, Overview limit rows and chart
/// segments. Codex keeps the selected palette; Claude Code takes its distinct sibling, turned 70 degrees and deeper
/// (a 50-degree pair proved too close). Warning colors never turn.
enum AgentPalette {
    static func hueShift(_ provider: SessionProvider) -> Double { provider == .claude ? 70.0 / 360 : 0 }
    /// A solid color for chart segments and legend dots: the palette's deepest full-allowance stop.
    static func color(_ provider: SessionProvider, accentHex: String?) -> AllowanceColor {
        AllowancePalette.colors(remaining: 100, tintHex: accentHex, hueShift: hueShift(provider))[2]
    }
}
