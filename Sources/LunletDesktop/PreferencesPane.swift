// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-24, AC-24.01, AC-24.02; US-22, AC-22.03; US-20, AC-20.02; US-21, AC-21.02, AC-21.04, AC-21.05; US-13, AC-13.11.
// Refs: US-40, AC-40.01, AC-40.02, AC-40.07.
// Refs: US-02, AC-02.07; US-04, AC-04.04; US-29, AC-29.05; US-19, AC-19.01; US-33, AC-33.08; US-14, AC-14.07.
// Refs: US-16, AC-16.01, AC-16.02; US-17, AC-17.01, AC-17.04, AC-17.08;
// Refs: US-18, AC-18.01; US-19, AC-19.01, AC-19.02, AC-19.03; US-20, AC-20.01; US-33, AC-33.07, AC-33.08;
// Refs: US-21, AC-21.01; US-22, AC-22.01, AC-22.02; US-26, AC-26.01, AC-26.02; US-31, AC-31.01, AC-31.02, AC-31.03, AC-31.04.
// Refs: US-35, AC-35.03, AC-35.04; US-38, AC-38.06; US-39, AC-39.06.
// Refs: US-41, AC-41.01, AC-41.02.
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

/// The pet choice: the built-in dog or a pack from Lunlet's or Codex's pets folder (AC-40.01).
private struct PetPackMenu: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var packs: PetPackLibrary
    private var selection: Binding<String> {
        Binding(get: { preferences.value.petPack ?? "" },
                set: { key in preferences.update { $0.petPack = key.isEmpty ? nil : key } })
    }
    var body: some View {
        SettingsRow("Pet", controlNamed: true) {
            Picker("Pet", selection: selection) {
                Text("Built-in dog").tag("")
                ForEach(packs.validEntries, id: \.reference.key) { entry in
                    Text("\(entry.displayName) · \(entry.reference.source.title)").tag(entry.reference.key)
                }
                if let chosen = preferences.value.petPack, !packs.validEntries.contains(where: { $0.reference.key == chosen }) {
                    Text("Unavailable pack").tag(chosen)
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        .help(PetPackLibrary.pickerHelp)
    }
}

/// The pack folders' actions and the reasons any pack cannot be used (AC-40.02, AC-40.07).
private struct PetPackActions: View {
    @ObservedObject var packs: PetPackLibrary
    var body: some View {
        SettingsRow("Packs") {
            HStack(spacing: PanelStyle.Space.margin) {
                Button("Refresh") { packs.refresh() }
                Button("Open pets folder") { packs.openLunletFolder() }
                Button("Find pets on Petdex") { packs.openGallery() }
                    .help("Opens the Petdex gallery in your browser; install a pet there with petdex install and it appears in this list.")
            }
            .buttonStyle(SettingsLinkButtonStyle())
        }
        let notes = [packs.chosenProblem, packs.truncationNote].compactMap { $0 } + packs.invalidEntries.map {
            "\($0.reference.folder) (\($0.reference.source.title)): \($0.failure?.description ?? "invalid")"
        }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                ForEach(Array(notes.enumerated()), id: \.offset) { Text($0.element).fixedSize(horizontal: false, vertical: true) }
            }
            .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
            .settingsCell()
        }
    }
}

/// Claude Code's two connections on the Agents page: shown while Claude Code is a selected agent, and whenever one
/// of them needs the owner's attention (AC-33.08, AC-38.06).
private struct ClaudeConnectionsGroup: View {
    @ObservedObject var limits: ClaudePlanLimitsModel
    @ObservedObject var hook: ClaudeHookModel
    let selected: Bool
    var body: some View {
        let needed = ClaudePlanLimitsSettings.status(connection: limits.connection, issue: limits.actionIssue).needsAttention
            || ClaudeHookSettings.status(connection: hook.connection, issue: hook.actionIssue).needsAttention
        if selected || needed {
            SettingsGroup(title: "Claude Code", note: "Lunlet keeps only percent used and reset times, and reads no credentials.") {
                ClaudePlanLimitsSettings(model: limits)
                ClaudeHookSettings(model: hook)
            }
        }
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
    @Environment(\.claudeHook) private var claudeHook
    @Environment(\.petPacks) private var petPacks
    @Environment(\.appUpdater) private var updater
    @Environment(\.allowanceNotifier) private var allowanceNotifier
    @ViewState private var category: PreferenceCategory
    @ViewState private var fileIssue: String?

    init(preferences: PreferencesStore, skins: SkinCatalog, setup: FeishuSetupModel, botSetup: BotChannelSetupModel,
         notifications: LockedCompletionNotifications, openConnection: @escaping () -> Void,
         initialCategory: PreferenceCategory? = nil) {
        self.preferences = preferences; self.skins = skins; self.setup = setup; self.botSetup = botSetup
        self.notifications = notifications; self.openConnection = openConnection; self.initialCategory = initialCategory
        // The page opens on its category at once, so the tab selection never slides there from Appearance.
        _category = ViewState(initialValue: SettingsModel.opening(initialCategory))
    }

    /// Five labeled icon tabs over the selected category's groups (AC-31.01, AC-31.04). A page made longer by an
    /// entry's own options scrolls; About is laid out to fit.
    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: Binding(get: { category }, set: { category = $0; fileIssue = nil }))
            if category == .about {
                // The page is laid out to fit the panel; only larger accessibility text makes it scroll.
                let about = SettingsAbout(preferences: preferences, skins: skins, updater: updater)
                ViewThatFits(in: .vertical) { about; ScrollView { about } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsStyle.groupGap) {
                        switch category {
                        case .appearance: appearance
                        case .usage: usage
                        case .agents: agents
                        case .messaging: messaging
                        case .about: EmptyView()
                        }
                        if let issue = fileIssue ?? preferences.issue ?? skins.issue {
                            Text(issue).font(PanelStyle.Text.secondary).foregroundStyle(.orange).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, PanelStyle.Grid.textInset)
                        }
                    }
                    .padding(.horizontal, PanelStyle.Grid.margin).padding(.bottom, PanelStyle.Space.medium)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .controlSize(.small)
        .onAppear { if let initialCategory { category = initialCategory } }
    }

    @ViewBuilder private var appearance: some View {
        let value = preferences.value
        let options = SettingsModel.entryOptions(value, packsListed: petPacks != nil)
        SettingsGroup(title: "Entry", note: SettingsModel.entryNote(value.presentation)) {
            SettingsEntryPicker(selection: binding(\.presentation), coat: value.petCoat).help(SettingsModel.entryHelp)
            if options.contains(.showAllowance) {
                // AC-21.04, AC-21.05: allowance text after the lettering, and the level below which it shows.
                SettingsRow("Show allowance", controlNamed: true) {
                    PanelSegmentedControl(selection: binding(\.menuBarAllowance),
                                          segments: MenuBarAllowance.allCases.map { .init(value: $0, title: $0.title) },
                                          size: .small, label: "Show allowance")
                }
                .help("Plain text after the lettering: the window closest to running out among those Lunlet shows, as the "
                    + "percent left, with its reset countdown if chosen. The agent's name is added with several agents and "
                    + "5h marks Codex's five-hour window. An unknown window shows no text.")
            }
            if options.contains(.onlyBelow) {
                SettingsRow("Only below", controlNamed: true) {
                    PanelSegmentedControl(selection: binding(\.menuBarAllowanceBelow), segments: Self.belowLevels,
                                          size: .small, label: "Only below")
                }
                .help("Show the text only while that window is below this percent left.")
            }
            if options.contains(.pet), let petPacks { PetPackMenu(preferences: preferences, packs: petPacks) }
            if options.contains(.coat) {
                SettingsRow("Coat", controlNamed: true) { SettingsCoatSwatches(selection: binding(\.petCoat)) }
            }
            if options.contains(.packs), let petPacks { PetPackActions(packs: petPacks) }
        }
        SettingsGroup(title: "Look", note: "The skin draws the strand beside the notch and sets the accent color.") {
            SettingsRow("Skin", controlNamed: true) {
                Picker("Skin", selection: binding(\.skinID)) {
                    ForEach(skins.skins) { Text($0.title).tag($0.id) }
                    if !skins.skins.contains(where: { $0.id == preferences.value.skinID }) {
                        Text("Unavailable skin").tag(preferences.value.skinID)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if skins.skin(id: preferences.value.skinID).allowsColorEditing {
                SettingsRow("Color") {
                    SkinColorControls(selection: colorBinding, isOverridden: preferences.value.accentHex != nil) {
                        preferences.update { $0.accentHex = nil }
                    }
                }
            }
            SettingsRow("Custom skins") {
                HStack(spacing: PanelStyle.Space.margin) {
                    Button("Import…") { importSkin() }
                    Button("Export template…") { exportSkin() }
                }
                .buttonStyle(SettingsLinkButtonStyle())
            }
        }
        // AC-13.11: one system sound with each Needs you cue, off by default.
        SettingsGroup(title: "Sound", note: "One system sound when a session starts waiting for you.") {
            SettingsRow("Sound for Needs you", controlNamed: true) { toggle("Sound for Needs you", \.needsYouSound) }
                .help("Plays the system alert sound once when a session starts waiting for your answer or approval, never "
                    + "for a start or a finish, and never while the display is locked or asleep.")
        }
    }
    private static let belowLevels: [PanelSegmentedControl<Int?>.Segment] =
        [.init(value: nil, title: "Always")] + LunletPreferences.menuBarAllowanceLevels.map { .init(value: $0, title: "\($0)% left") }

    @ViewBuilder private var usage: some View {
        SettingsGroup(title: "History", note: "How many days the charts and totals cover.") {
            SettingsRow("Days", controlNamed: true) {
                PanelSegmentedControl(selection: binding(\.historyDays), segments: (1...7).map {
                    .init(value: $0, title: String($0), accessibilityLabel: $0 == 1 ? "1 day" : "\($0) days")
                }, size: .small, label: "Usage history days")
            }
        }
        // Allowance notifications: the switch, the level and the reset notice (AC-41.01, AC-41.02).
        SettingsGroup(title: "Notifications",
                      note: "Official readings only: never estimates, never through messaging.") {
            SettingsRow("Allowance notifications", controlNamed: true) { toggle("Allowance notifications", \.allowanceNotifications) }
                .help("A macOS notification when a window Lunlet shows drops below the level, and when it resets. "
                    + "Only official readings, never estimates, and never through the messaging channel.")
                .onAppear { allowanceNotifier?.checkAuthorization() }
            if preferences.value.allowanceNotifications {
                SettingsRow("Warn below", controlNamed: true) {
                    PanelSegmentedControl(selection: binding(\.allowanceWarnBelow), segments: LunletPreferences.allowanceWarnLevels.map {
                        .init(value: $0, title: "\($0)% left")
                    }, size: .small, label: "Warn below")
                }
                SettingsRow("When a window resets", controlNamed: true) { toggle("When a window resets", \.allowanceResetNotices) }
                if let allowanceNotifier { AllowancePermissionNote(notifier: allowanceNotifier) }
            }
        }
        // AC-04.04: the source, purpose and destination of each figure, with credential handling in help.
        SettingsGroup(title: "Where the numbers come from") {
            ForEach(SettingsModel.sources(providers: preferences.value.providers), id: \.label) { source in
                SettingsRow(source.label) { Text(source.value).foregroundStyle(.secondary).lineLimit(1) }
                    .help(source.help ?? "")
                    .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var agents: some View {
        SettingsGroup(title: "Show agents", note: "Several agents open on the Overview. One agent always stays on.") {
            ForEach(AgentProvider.allCases) { agent in
                SettingsRow(agent.title, detail: SettingsModel.agentDetail(agent), controlNamed: true) {
                    Toggle(agent.title, isOn: Binding(get: { preferences.value.providers.contains(agent) }, set: { selected in
                        preferences.update { $0.providers = SettingsModel.toggled(agent, on: selected, in: $0.providers) }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!SettingsModel.canTurnOff(agent, selected: preferences.value.providers))
                }
                // The switch itself says what selecting the agent changes outside Lunlet (AC-33.08, AC-38.06).
                .help(agent.switchHelp ?? "")
            }
        }
        ClaudeConnectionsGroup(limits: claudeLimits ?? .placeholder, hook: claudeHook ?? .placeholder,
                               selected: preferences.value.providers.contains(.claude))
    }

    @ViewBuilder private var messaging: some View {
        let feishu = preferences.value.channel == .feishu
        let name = feishu ? setup.platformName : preferences.value.channel.title
        let stages = feishu
            ? setup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
            : botSetup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
        SettingsGroup(title: "Communication", note: "One private channel for notices and replies while you are away from the Mac. "
                        + "Execution approvals stay on the Mac.") {
            SettingsRow("Channel", controlNamed: true) {
                PanelSegmentedControl(selection: binding(\.channel),
                                      segments: CommunicationChannel.allCases.map { .init(value: $0, title: $0.title) },
                                      size: .small, label: "Channel")
            }
            SettingsRow("Status") {
                let health = ChannelHealth(stages: stages)
                Label(health.word, systemImage: health.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(health.tone == .neutral ? Color.secondary : health.tone.color)
            }
            .help(notifications.status.explanation)
            .accessibilityElement(children: .combine)
            // The attached connection card shows these same stages (AC-22.03).
            DisclosureGroup("Connection details") {
                ReadinessStageList(stages: stages).padding(.top, PanelStyle.Space.tight)
            }
            .font(PanelStyle.Text.primary)
            .settingsCell()
            if feishu, case .enrolled = setup.state, ![.notChecked, .unavailable].contains(notifications.authorizationCheck) {
                Text(notifications.authorizationCheck.explanation).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).settingsCell()
            }
            HStack {
                Button("Manage " + name + "…", action: openConnection)
                Spacer()
                if feishu, case .enrolled = setup.state {
                    Button("Check authorization", action: setup.checkAuthorization)
                        .disabled(notifications.authorizationCheck == .checking)
                }
            }
            .buttonStyle(SettingsLinkButtonStyle())
            .settingsCell()
        }
    }

    /// A small system switch whose label stays for assistive tools; the row shows the name.
    private func toggle(_ title: String, _ key: WritableKeyPath<LunletPreferences, Bool>) -> some View {
        Toggle(title, isOn: binding(key)).labelsHidden().toggleStyle(.switch)
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

/// One page with no scrolling: the lettering and version, what Lunlet is, the facts of AC-29.05 in a compact grid,
/// a release build's update controls and, along the bottom edge, the error log and the copyright line.
struct SettingsAbout: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var skins: SkinCatalog
    let updater: AppUpdater?

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.small) {
            Group {
                HStack(spacing: PanelStyle.Space.module) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
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
            }
            .padding(.horizontal, PanelStyle.Grid.textInset)
            // Present only in a configured release build (AC-35.03, AC-35.04).
            UpdateSettingsSection(updater: updater)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                errorLog
                Spacer()
                Text("© 2026 yukunlabs").foregroundStyle(.secondary)
            }
            .font(Font.caption)
            .padding(.horizontal, PanelStyle.Grid.textInset)
        }
        .font(Font.body)
        .padding(.horizontal, PanelStyle.Grid.margin).padding(.top, PanelStyle.Space.hairline).padding(.bottom, PanelStyle.Space.small)
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
        .buttonStyle(SettingsLinkButtonStyle())
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
}
