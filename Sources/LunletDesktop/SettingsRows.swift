// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-31, AC-31.01, AC-31.02, AC-31.04; US-24, AC-24.01, AC-24.02; US-21, AC-21.01; US-39, AC-39.06.
import AppKit
import LunletCore
import SwiftUI

/// Measurements of the Settings page that the panel's own tokens do not name.
enum SettingsStyle {
    /// The icon tabs with their margins; the page below them takes the rest of the panel's page budget.
    static let tabBarHeight: CGFloat = 58
    static let tabHeight: CGFloat = 46
    static let tabRadius: CGFloat = 10
    /// One row of a group: a label and its control.
    static let rowHeight: CGFloat = 30
    static let groupGap: CGFloat = PanelStyle.Space.module
    static let headingGap: CGFloat = 5
    static let hairline: CGFloat = 0.5
    /// A pictured entry option.
    static let entryPicture = CGSize(width: 58, height: 25)
    static let entryRadius: CGFloat = 9
    static let swatch: CGFloat = 16
}

/// The five categories as labeled icons, the selected one on an elevated fill with its icon in the tint. One
/// focusable control: arrows move the selection, as in the panel's segmented controls (AC-24.01).
struct SettingsTabBar: View {
    @Binding var selection: PreferenceCategory
    @Namespace private var namespace
    @FocusState private var focused: Bool
    @ViewState private var hovered: PreferenceCategory?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            ForEach(SettingsModel.tabs, id: \.self) { tab($0) }
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: SettingsStyle.tabRadius, style: .continuous)
                    .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-1.5).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, PanelStyle.Grid.margin)
        .frame(height: SettingsStyle.tabBarHeight)
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .animation(PanelStyle.selection(reduce: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
        .accessibilityAddTraits(.isTabBar)
    }

    private func tab(_ item: PreferenceCategory) -> some View {
        let selected = item == selection
        let shape = RoundedRectangle(cornerRadius: SettingsStyle.tabRadius, style: .continuous)
        return VStack(spacing: 3) {
            Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).frame(height: 18)
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            // Sized for the semibold selection so choosing a tab never shifts the labels.
            Text(item.rawValue).fontWeight(.semibold).hidden()
                .overlay { Text(item.rawValue).fontWeight(selected ? .semibold : .regular) }
                .font(PanelStyle.Text.secondary).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: SettingsStyle.tabHeight)
        .background {
            if selected {
                shape.fill(scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.9))
                    .overlay { if contrast == .increased { shape.strokeBorder(PanelStyle.separator, lineWidth: 1) } }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.12), radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovered == item {
                shape.fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .onTapGesture { selection = item }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsModel.tabLabel(item))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = item }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        if let next = SettingsModel.neighbor(of: selection, offset: offset) { selection = next }
        return .handled
    }
}

/// One group of related settings: a short heading, a rounded module whose rows are parted by hairlines, and one
/// note saying what the group changes (AC-31.01, AC-31.02).
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.Radius.module, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(PanelStyle.Text.secondary.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, PanelStyle.Grid.textInset).padding(.bottom, SettingsStyle.headingGap)
                    .accessibilityAddTraits(.isHeader)
            }
            // Every row draws a hairline under itself; the last one falls just outside the module and is clipped.
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, -1)
                .clipShape(shape)
                .background(PanelStyle.moduleFill, in: shape)
                .overlay { shape.strokeBorder(contrast == .increased ? AnyShapeStyle(PanelStyle.separator) : AnyShapeStyle(PanelStyle.moduleStroke),
                                              lineWidth: contrast == .increased ? 1 : 0.5) }
            if let note {
                Text(note).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PanelStyle.Grid.textInset).padding(.top, SettingsStyle.headingGap)
            }
        }
    }
}

private struct SettingsSeparator: ViewModifier {
    @Environment(\.displayScale) private var scale
    func body(content: Content) -> some View {
        // One device pixel: half a point on a Retina display, a whole point where half would round away.
        content.overlay(alignment: .bottom) {
            Rectangle().fill(PanelStyle.separator).frame(height: max(SettingsStyle.hairline, 1 / max(1, scale)))
                .padding(.leading, PanelStyle.Grid.textInset).accessibilityHidden(true)
        }
    }
}
extension View {
    /// The hairline under a row of a settings group.
    func settingsSeparator() -> some View { modifier(SettingsSeparator()) }
    /// Free-form content of a settings group, padded and parted like its rows.
    func settingsCell() -> some View {
        padding(.horizontal, PanelStyle.Grid.textInset).padding(.vertical, PanelStyle.Space.small)
            .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
            .settingsSeparator()
    }
}

/// A setting: its name at the leading edge, with an optional line saying what it changes, and its control at the
/// trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    /// A switch, menu or segmented control that carries the row's name itself; VoiceOver then reads the name once,
    /// from the control.
    var controlNamed = false
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, controlNamed: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.controlNamed = controlNamed; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: PanelStyle.Space.margin) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PanelStyle.Text.primary).foregroundStyle(.primary).lineLimit(1).fixedSize()
                    .accessibilityHidden(controlNamed)
                if let detail {
                    Text(detail).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control.font(PanelStyle.Text.secondary)
        }
        .padding(.horizontal, PanelStyle.Grid.textInset).padding(.vertical, PanelStyle.Space.tight)
        .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
        .settingsSeparator()
    }
}

/// A text action in the tint, such as Import or Try again: quieter than a bordered button in a dense row, with a
/// 20-point target.
struct SettingsLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SettingsLinkButton(configuration: configuration) }
}
private struct SettingsLinkButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(PanelStyle.Text.secondary.weight(.semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .lineLimit(1).fixedSize()
            .frame(minHeight: PanelStyle.Layout.inlineButton)
            .contentShape(Rectangle())
    }
}

/// A connection's state in a row: a status word with its dot when all is well, otherwise the note that says what
/// happened and the one action it needs (AC-31.02, AC-24.02).
struct SettingsStatusRow: View {
    let title: String
    let status: SettingsStatus
    var actionHelp: String? = nil
    let perform: (SettingsStatus.Action) -> Void

    var body: some View {
        if status.needsAttention {
            HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.margin) {
                VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                    Label(title, systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                        .font(PanelStyle.Text.primary).symbolRenderingMode(.multicolor)
                    Text(status.text).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let action = status.action {
                    Button(action == .forget ? "Forget" : "Try again") { perform(action) }
                        .buttonStyle(SettingsLinkButtonStyle()).help(actionHelp ?? "")
                }
            }
            .settingsCell()
        } else {
            SettingsRow(title) { SettingsStatusLabel(text: status.text, tone: status.tone) }
                .accessibilityElement(children: .combine)
        }
    }
}

/// A status word with a dot in its tone; the word alone says the state.
struct SettingsStatusLabel: View {
    let text: String
    let tone: PanelTone
    var body: some View {
        HStack(spacing: PanelStyle.Space.small) {
            Circle().fill(tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).fontWeight(tone == .neutral ? .regular : .semibold)
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        }
        .font(PanelStyle.Text.secondary).lineLimit(1).fixedSize()
    }
}

/// The entry as three pictured options, the selected one ringed in the tint (AC-21.01).
struct SettingsEntryPicker: View {
    @Binding var selection: EntryPresentation
    var coat: PetCoat = .golden
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: PanelStyle.Space.medium) {
            ForEach(SettingsModel.entries, id: \.self) { option($0) }
        }
        .padding(PanelStyle.Space.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Presentation")
        .settingsSeparator()
    }

    private func option(_ entry: EntryPresentation) -> some View {
        let selected = entry == selection
        let shape = RoundedRectangle(cornerRadius: SettingsStyle.entryRadius, style: .continuous)
        return Button { selection = entry } label: {
            VStack(spacing: PanelStyle.Space.tight) {
                SettingsEntryPicture(entry: entry, coat: coat)
                    .frame(width: SettingsStyle.entryPicture.width, height: SettingsStyle.entryPicture.height)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .accessibilityHidden(true)
                Text(entry.title).fontWeight(.semibold).hidden()
                    .overlay { Text(entry.title).fontWeight(selected ? .semibold : .regular) }
                    .font(PanelStyle.Text.secondary).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045), in: shape)
            .overlay {
                if selected { shape.strokeBorder(.tint, lineWidth: 1.5) }
                else if contrast == .increased { shape.strokeBorder(PanelStyle.separator, lineWidth: 1) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small drawing of where each entry lives: beside the notch, in the menu bar, or as the dog on the desktop.
struct SettingsEntryPicture: View {
    let entry: EntryPresentation
    var coat: PetCoat = .golden

    var body: some View {
        Canvas { context, size in
            // Drawn in a 64 x 28 design space.
            context.scaleBy(x: size.width / 64, y: size.height / 28)
            let ink = GraphicsContext.Shading.style(.foreground)
            context.stroke(Path(roundedRect: CGRect(x: 1, y: 1, width: 62, height: 26), cornerRadius: 5), with: ink, lineWidth: 1)
            func bar(_ x: CGFloat, _ width: CGFloat, opacity: Double = 1) {
                var tinted = context; tinted.opacity = opacity
                tinted.fill(Path(roundedRect: CGRect(x: x, y: 3.5, width: width, height: 3), cornerRadius: 1.5), with: .style(.tint))
            }
            func dot(_ x: CGFloat) {
                var quiet = context; quiet.opacity = 0.55
                quiet.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: 3.5, width: 3, height: 3)), with: ink)
            }
            switch entry {
            case .notch:
                context.fill(Path(roundedRect: CGRect(x: 22, y: 1, width: 20, height: 7.5), cornerRadius: 3), with: ink)
                bar(9, 10); bar(45, 10, opacity: 0.55)
            case .menuBar:
                context.stroke(Path { $0.move(to: .init(x: 1.5, y: 9)); $0.addLine(to: .init(x: 62.5, y: 9)) }, with: ink, lineWidth: 1)
                bar(38, 13); dot(33); dot(56.5)
            case .pet:
                let palette = PetPalette.make(coat: coat, accent: .init(hex: 0x856bc7))
                context.stroke(Path { $0.move(to: .init(x: 36.5, y: 19)); $0.addQuadCurve(to: .init(x: 34.9, y: 15), control: .init(x: 33.6, y: 18)) },
                               with: .color(palette.coat), style: .init(lineWidth: 1.6, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: 36, y: 15.9, width: 16, height: 9.2)), with: .color(palette.coat))
                context.fill(Path(ellipseIn: CGRect(x: 46.4, y: 9.9, width: 9.2, height: 9.2)), with: .color(palette.coat))
                context.fill(Path { $0.move(to: .init(x: 48, y: 12)); $0.addLine(to: .init(x: 45.8, y: 8.6)); $0.addLine(to: .init(x: 50.2, y: 9.8)); $0.closeSubpath() },
                             with: .color(palette.ear))
                context.fill(Path(ellipseIn: CGRect(x: 51.8, y: 13.2, width: 1.6, height: 1.6)), with: .color(palette.dark))
            }
        }
    }
}

/// The built-in dog's coats as swatches, the chosen one ringed in the tint (AC-39.06).
struct SettingsCoatSwatches: View {
    @Binding var selection: PetCoat

    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            ForEach(PetCoat.allCases, id: \.self) { coat in
                let selected = coat == selection
                Button { selection = coat } label: {
                    Circle().fill(PetPalette.make(coat: coat, accent: .init(hex: 0x856bc7)).coat)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: SettingsStyle.swatch, height: SettingsStyle.swatch)
                        .padding(3)
                        .overlay { if selected { Circle().strokeBorder(.tint, lineWidth: 1.5) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(coat.title)
                .accessibilityLabel(coat.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coat")
    }
}
