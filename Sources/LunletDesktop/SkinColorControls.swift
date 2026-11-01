// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01, AC-16.02; US-17, AC-17.08; US-24, AC-24.01.
import AppKit
import SwiftUI

/// Continuous hue editing and the system picker for the complete RGB range.
struct SkinColorControls: View {
    @Binding var selection: Color
    let isOverridden: Bool
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            HueSpectrum(selection: $selection).frame(width: 125, height: 24)
            ColorPicker("Custom color", selection: $selection, supportsOpacity: false)
                .labelsHidden().frame(width: 25)
                .help("Adjust the full RGB color")
            Button("Restore", action: reset)
                .buttonStyle(.bordered).controlSize(.mini).font(Font.caption)
                .fixedSize().disabled(!isOverridden)
                .help("Restore the skin's default colors")
                .accessibilityLabel("Restore default skin color")
        }.fixedSize()
    }
}

private struct HueSpectrum: View {
    @Binding var selection: Color
    @FocusState private var focused: Bool
    @ViewState private var editing = HueEditingState()
    private let thumbSize: CGFloat = 16
    private var rgb: NSColor { NSColor(selection).usingColorSpace(.sRGB) ?? .systemPurple }
    private var hue: Double { editing.hue }
    private var spectrum: [Color] {
        (0...12).map { Color(hue: Double($0) / 12, saturation: 0.72, brightness: 0.94) }
    }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - thumbSize)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .frame(height: 8).padding(.horizontal, thumbSize / 2)
                Circle().fill(selection)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(Circle().strokeBorder(.primary.opacity(focused ? 0.25 : 0), lineWidth: 0.5))
                    .offset(x: travel * hue)
            }
            .frame(height: geometry.size.height).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                focused = true
                setHue(Double((value.location.x - thumbSize / 2) / travel))
            })
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { editing.synchronize(rgb) }
        .onChange(of: selection) { _, _ in editing.synchronize(rgb) }
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: setHue(hue - 0.01)
            case .right, .up: setHue(hue + 0.01)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skin hue")
        .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setHue(hue + 0.01)
            case .decrement: setHue(hue - 0.01)
            @unknown default: break
            }
        }
        .help("Drag to choose any hue; use the color well for full RGB adjustment")
    }

    private func setHue(_ value: Double) {
        selection = Color(nsColor: editing.choose(value, from: rgb))
    }
}

/// RGB cannot retain hue at both red endpoints or in neutral colors.
/// Keep the editing position through our own 8-bit preference round trips.
struct HueEditingState {
    private(set) var hue = 0.0
    private var appliedRGB: Int?

    mutating func synchronize(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB), key(rgb) != appliedRGB else { return }
        hue = Double(rgb.hueComponent)
        appliedRGB = nil
    }

    mutating func choose(_ value: Double, from color: NSColor) -> NSColor {
        let current = color.usingColorSpace(.sRGB) ?? .systemPurple
        hue = min(1, max(0, value))
        // Entering the spectrum from a neutral shade must produce a visible hue.
        let selected = NSColor(hue: hue,
                               saturation: current.saturationComponent > 0 ? current.saturationComponent : 0.72,
                               brightness: current.brightnessComponent > 0 ? current.brightnessComponent : 0.94,
                               alpha: 1)
        appliedRGB = key(selected)
        return selected
    }

    private func key(_ color: NSColor) -> Int {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemPurple
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return channels.reduce(0) { ($0 << 8) | Int((min(1, max(0, $1)) * 255).rounded()) }
    }
}
