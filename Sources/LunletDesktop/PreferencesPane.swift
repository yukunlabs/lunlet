// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-24, AC-24.01, AC-24.02; US-22, AC-22.03; US-20, AC-20.02; US-21, AC-21.02.
// Refs: US-02, AC-02.07; US-04, AC-04.04; US-29, AC-29.05; US-19, AC-19.01; US-33, AC-33.08; US-14, AC-14.07.
// Refs: US-16, AC-16.01, AC-16.02; US-17, AC-17.01, AC-17.04, AC-17.08;
// Refs: US-18, AC-18.01; US-19, AC-19.01, AC-19.02, AC-19.03; US-20, AC-20.01; US-33, AC-33.07, AC-33.08;
// Refs: US-21, AC-21.01; US-22, AC-22.01, AC-22.02; US-26, AC-26.01, AC-26.02; US-31, AC-31.01, AC-31.02, AC-31.03, AC-31.04.
// Refs: US-35, AC-35.03, AC-35.04.
import AppKit
import LunletCore
import SwiftUI
import UniformTypeIdentifiers

enum PreferenceCategory: String, CaseIterable {
    case appearance = "Appearance", usage = "Usage", agents = "Agents", messaging = "Messaging", about = "About"
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"; case .usage: "chart.bar"
        case .agents: "terminal"; case .messaging: "bubble.left.and.bubble.right"; case .about: "info.circle"
        }
    }
}

private struct OpenSettingsKey: EnvironmentKey { static var defaultValue: ((PreferenceCategory) -> Void)? { nil } }
extension EnvironmentValues {
    /// Opens Settings on a category; it only navigates and never changes a setting.
    var openSettings: ((PreferenceCategory) -> Void)? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

struct PreferencesPane: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var skins: SkinCatalog
    @ObservedObject var setup: FeishuSetupModel
    @ObservedObject var botSetup: BotChannelSetupModel
    @ObservedObject var notifications: LockedCompletionNotifications
    let openConnection: () -> Void
    /// The category to show first, such as Agents when a page asks to connect Claude plan limits.
    var initialCategory: PreferenceCategory? = nil
    @Environment(\.claudePlanLimits) private var claudeLimits
    @Environment(\.appUpdater) private var updater
    @ViewState private var category = PreferenceCategory.appearance
    @ViewState private var fileIssue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                ForEach(PreferenceCategory.allCases, id: \.self) { item in
                    let selected = category == item
                    Button { category = item; fileIssue = nil } label: {
                        HStack(spacing: 7) {
                            // A fixed symbol column keeps every label aligned.
                            Image(systemName: item.symbol).frame(width: 18)
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .accessibilityHidden(true)
                            Text(item.rawValue).foregroundStyle(.primary).lineLimit(1)
                        }
                        .font(Font.body)
                        .padding(.horizontal, PanelStyle.Space.medium)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(item.rawValue + " settings")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, PanelStyle.Space.medium).padding(.top, PanelStyle.Space.tight).frame(width: 136)
            Rectangle().fill(PanelStyle.separator).frame(width: 0.5)
            if category == .about {
                // The page is laid out to fit the panel; only larger accessibility text makes it scroll.
                ViewThatFits(in: .vertical) { about; ScrollView { about } }
            } else {
                Form {
                    switch category {
                    case .appearance: appearance
                    case .usage: usage
                    case .agents: agents
                    case .messaging: messaging
                    case .about: EmptyView()
                    }
                    if let issue = fileIssue ?? preferences.issue ?? skins.issue {
                        Text(issue).font(Font.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .formStyle(.grouped).scrollContentBackground(.hidden).controlSize(.small)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if let initialCategory { category = initialCategory } }
    }

    private var appearance: some View {
        Group {
            Section {
                Picker("Presentation", selection: binding(\.presentation)) {
                    ForEach(EntryPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Skin", selection: binding(\.skinID)) {
                    ForEach(skins.skins) { Text($0.title).tag($0.id) }
                    if !skins.skins.contains(where: { $0.id == preferences.value.skinID }) {
                        Text("Unavailable skin").tag(preferences.value.skinID)
                    }
                }
                if skins.skin(id: preferences.value.skinID).allowsColorEditing {
                    LabeledContent("Color") {
                        SkinColorControls(selection: colorBinding,
                                          isOverridden: preferences.value.accentHex != nil) {
                            preferences.update { $0.accentHex = nil }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("Custom skins") {
                    HStack {
                        Button("Import…") { importSkin() }
                        Button("Export template…") { exportSkin() }
                    }
                }
            }
        }
    }
    private var usage: some View {
        Group {
            Section {
                Picker("Days", selection: binding(\.historyDays)) {
                    ForEach(1...7, id: \.self) { day in
                        Text(String(day)).tag(day).accessibilityLabel(day == 1 ? "1 day" : "\(day) days")
                    }
                }.pickerStyle(.segmented)
                    .accessibilityLabel("Usage history days")
            } header: {
                Text("History")
            } footer: {
                Text("Local Codex sign-in · OpenAI account limits")
                    .font(Font.caption).foregroundStyle(.secondary)
                    .help("Account identity and limits are read automatically through Codex. Sign-in credentials are never sent "
                        + "through messaging channels. Quitting cancels owned reads.")
            }
        }
    }
    private var agents: some View {
        Group {
            Section {
                ForEach(AgentProvider.allCases) { agent in
                    Toggle(agent.title, isOn: Binding(get: { preferences.value.providers.contains(agent) }, set: { selected in
                        preferences.update { value in
                            if selected { if !value.providers.contains(agent) { value.providers.append(agent) } }
                            else { value.providers.removeAll { $0 == agent } }
                        }
                    }))
                    .disabled(preferences.value.providers == [agent])
                }
            } header: {
                Text("Show agents")
            } footer: {
                Text("Several agents share an Overview tab · Claude Code: local sessions and usage")
                    .font(Font.caption).foregroundStyle(.secondary)
                    .help("Claude Code is observed from its own local session records and transcripts, without hooks or sockets. "
                        + "While it is selected, Lunlet adds a status line to Claude Code's settings.json for plan limits (a custom "
                        + "status line hides most footer keyboard hints) and keeps any existing one running; turning Claude Code off "
                        + "restores the previous status line exactly. Only the account email and plan are kept from Claude Code's "
                        + "profile; credentials and environment values are never read.")
            }
            ClaudePlanLimitsSettings(model: claudeLimits ?? .placeholder)
        }
    }
    private var messaging: some View {
        let feishu = preferences.value.channel == .feishu
        let name = feishu ? setup.platformName : preferences.value.channel.title
        let stages = feishu
            ? setup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
            : botSetup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
        return Section {
            Picker("Channel", selection: binding(\.channel)) {
                ForEach(CommunicationChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            LabeledContent("Status") {
                let health = ChannelHealth(stages: stages)
                Label(health.word, systemImage: health.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(health.tone == .neutral ? Color.secondary : health.tone.color)
            }
            .help(notifications.status.explanation)
            // The attached connection card shows these same stages (AC-22.03).
            DisclosureGroup("Connection details") {
                ForEach(stages) { stage in
                    LabeledContent {
                        Text(stage.value).foregroundStyle(ReadinessStage.valueStyle(stage.tone))
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label(stage.id, systemImage: stage.symbol)
                            .foregroundStyle(stage.tone == .neutral ? Color.primary : stage.tone.color)
                    }
                    .font(Font.caption)
                    .accessibilityElement(children: .combine)
                }
            }
            if feishu, case .enrolled = setup.state, ![.notChecked, .unavailable].contains(notifications.authorizationCheck) {
                Text(notifications.authorizationCheck.explanation).font(Font.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Manage " + name + "…", action: openConnection)
                Spacer()
                if feishu, case .enrolled = setup.state {
                    Button("Check authorization", action: setup.checkAuthorization)
                        .disabled(notifications.authorizationCheck == .checking)
                }
            }
        } header: {
            Text("Communication")
        }
    }
    /// One page with no scrolling: the lettering and version, what Lunlet is, the facts of AC-29.05 in a compact
    /// grid, a release build's update controls and, along the bottom edge, the error log and the copyright line.
    private var about: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.medium) {
            HStack(spacing: PanelStyle.Space.module) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                    // The app names itself with the same lun·let lettering as the notch and menu-bar entries.
                    Image(nsImage: LunletWordmark.image(height: LunletWordmark.aboutHeight)).renderingMode(.template)
                        .foregroundStyle(skins.controlTint(for: preferences.value).color)
                        .accessibilityLabel("Lunlet")
                    Text(Self.version).font(Font.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text("A notch companion for your Codex and Claude Code sessions.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // The facts read at the panel's secondary size, so they stay on one page beside the update controls.
            Grid(alignment: .topLeading, horizontalSpacing: PanelStyle.Space.margin, verticalSpacing: PanelStyle.Space.tight) {
                fact("Developer", "yukunlabs")
                fact("License", "Open source · 0BSD · free for everyone",
                     help: "Anyone may use, copy, modify and distribute Lunlet for any purpose, with or without fee.")
                fact("Includes", "SwiftProtobuf · Apache-2.0\nSparkle · MIT",
                     help: "Their licenses, including those of the code Sparkle bundles, and Lunlet's notices ship inside "
                        + "the application bundle.")
                fact("Privacy", "Runs on this Mac with no analytics. Credentials stay on this Mac in a file only your user "
                     + "can read, sealed for this Mac; notices go only to the channel you set up.")
            }
            .font(Font.subheadline)
            // Present only in a configured release build (AC-35.03, AC-35.04).
            UpdateSettingsSection(updater: updater)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                errorLog
                Spacer()
                Text("© 2026 yukunlabs").foregroundStyle(.secondary)
            }
            .font(Font.caption)
        }
        .font(Font.body)
        .padding(.horizontal, PanelStyle.Space.large).padding(.vertical, PanelStyle.Space.module)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func fact(_ label: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            let text = Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let help { text.help(help) } else { text }
        }
        .accessibilityElement(children: .combine)
    }
    /// The local error log for troubleshooting: errors only, no content, never uploaded (AC-14.07).
    private var errorLog: some View {
        let log = DiagnosticLog.file?.url ?? DiagnosticFile.standard, folder = log.deletingLastPathComponent()
        return Button("Show error log in Finder") {
            let target = FileManager.default.fileExists(atPath: log.path) ? log : folder
            if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        }
        .buttonStyle(.link)
        .disabled(!FileManager.default.fileExists(atPath: folder.path))
        .help("Errors only, with no conversation content, account or session identifiers, rotated at 256 KB and "
            + "never uploaded: ~/Library/Logs/Lunlet/lunlet.log")
    }
    /// "0.1.0 (1)" from the bundle; an unbundled development run says so.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return (info?["CFBundleVersion"] as? String).map { "Version \(short) (\($0))" } ?? "Version " + short
    }

    private func binding<Value>(_ key: WritableKeyPath<LunletPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences.value[keyPath: key] }, set: { value in preferences.update { $0[keyPath: key] = value } })
    }
    private var selectedColor: NSColor {
        let hex = skins.displayedAccentHex(for: preferences.value)
        return (AllowanceColor(hexString: hex) ?? skins.skin(id: preferences.value.skinID).kind.fallbackAccent).nsColor
    }
    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: selectedColor) }, set: { setColor(NSColor($0)) })
    }
    private func setColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let hex = String(format: "#%02X%02X%02X", Int((min(1, max(0, rgb.redComponent)) * 255).rounded()),
                         Int((min(1, max(0, rgb.greenComponent)) * 255).rounded()), Int((min(1, max(0, rgb.blueComponent)) * 255).rounded()))
        preferences.update { $0.accentHex = hex }
    }
    private func importSkin() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let skin = try skins.install(file.read(upToCount: 65_537) ?? Data())
            preferences.update { $0.skinID = skin.id }; fileIssue = nil
        } catch { fileIssue = "This skin is invalid or could not be installed. Your existing skin was kept." }
    }
    private func exportSkin() {
        var skin = skins.skin(id: preferences.value.skinID)
        if skin.allowsColorEditing { skin.accentHex = skin.resolvedAccent(override: preferences.value.accentHex) }
        if SkinCatalog.builtins.contains(where: { $0.id == skin.id }) { skin.id = "my-skin"; skin.title = "My skin" }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = skin.id + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(skin).write(to: url, options: .atomic); fileIssue = nil
        } catch { fileIssue = "The skin template could not be exported to that location." }
    }
}
