// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.02, AC-20.04, AC-20.06; US-12, AC-12.02; US-22, AC-22.02, AC-22.03.
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import LunletMessaging

struct BotChannelSetupPanel: View {
    @ObservedObject var model: BotChannelSetupModel
    @ObservedObject var notifications: LockedCompletionNotifications
    @ViewBuilder var body: some View {
        switch model.state {
        case .disconnected, .failed:
            if let issue = model.issue { SetupAlert(text: issue) }
            credentials
        case .loading: ProgressView("Reading saved connection…").controlSize(.small)
        case .connecting:
            HStack {
                ProgressView("Checking bot…").controlSize(.small)
                Spacer()
                Button("Cancel", action: model.cancel).controlSize(.small)
            }
        case .saving: ProgressView("Saving connection…").controlSize(.small)
        case .disconnecting: ProgressView("Disconnecting…").controlSize(.small)
        case .pairing:
            pairing
            HStack { Spacer(); Button("Cancel", action: model.cancel).controlSize(.small) }
        case .enrolled:
            if let binding = model.binding { SetupNote(text: binding.botName) }
            HStack {
                // Quiet like the Feishu card's removal: the check is the action this row is for.
                Button("Disconnect", role: .destructive, action: model.disconnect).buttonStyle(.borderless).controlSize(.small)
                Spacer()
                Button("Check authorization", action: model.checkAuthorization).controlSize(.small)
                    .disabled(notifications.authorizationCheck == .checking)
            }
            if ![.unavailable, .notChecked].contains(notifications.authorizationCheck) {
                SetupNote(text: notifications.authorizationCheck.explanation)
            }
        case .accessRequired:
            SetupAlert(text: model.issue ?? "Authorize access to your saved connection.", tone: .attention)
            HStack {
                // Pasting the token again needs no Keychain prompt, so clearing is offered beside authorizing.
                Button("Clear and paste again", action: model.disconnect).buttonStyle(.borderless).controlSize(.small)
                Spacer()
                Button("Authorize access", action: model.authorize).buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .signingRequired:
            SetupAlert(text: "Install a signed Lunlet build to connect your bot.", tone: .attention)
        }
    }
    /// Two steps to a bot of the owner's own, each field naming the provider menu its value comes from (AC-20.04).
    private var credentials: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.module) {
            if model.channel == .slack {
                SetupStep(number: 1, title: "Create the Slack app") {
                    HStack(spacing: PanelStyle.Space.small) {
                        Link("Create Slack bot", destination: BotSetupLinks.slackManifest)
                        Text("·").foregroundStyle(.tertiary)
                        Link("Use existing app", destination: URL(string: "https://api.slack.com/apps")!)
                    }.font(Font.subheadline)
                    SetupNote(text: "The link opens Slack with the permissions and Socket Mode filled in; install the app to your workspace.")
                    DisclosureGroup("What an existing app needs") {
                        SetupNote(text: "Bot scopes chat:write, im:history and users:read; Socket Mode with the message.im event; "
                            + "the Messages tab; an app-level token with connections:write.")
                    }.font(Font.caption)
                }
                SetupStep(number: 2, title: "Paste its tokens") {
                    credentialField("Bot token", hint: "xoxb-…", source: "OAuth & Permissions → Bot User OAuth Token",
                                    text: $model.draftBotToken)
                    credentialField("App token", hint: "xapp-…", source: "Basic Information → App-Level Tokens (connections:write)",
                                    text: $model.draftAppToken)
                }
            } else {
                SetupStep(number: 1, title: "Create the bot in BotFather") {
                    Link("Open BotFather", destination: URL(string: "https://t.me/BotFather")!).font(Font.subheadline)
                    SetupNote(text: "New bot: send /newbot. Existing bot: /mybots → your bot → API Token.")
                }
                SetupStep(number: 2, title: "Paste the bot token") {
                    credentialField("Bot token", hint: "Token from BotFather", text: $model.draftBotToken)
                }
            }
            HStack(alignment: .center) {
                Label("Tokens stay in your Keychain", systemImage: "lock.fill")
                    .font(Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Use a bot dedicated to Lunlet. Tokens are saved only in macOS Keychain and never leave this Mac.")
                Spacer(minLength: PanelStyle.Space.medium)
                if model.reloadAvailable { Button("Reload saved connection", action: model.reload).controlSize(.small) }
                Button("Connect") {
                    guard let channel = model.channel else { return }
                    let credentials = BotCredentials(channel: channel,
                        botToken: model.draftBotToken.trimmingCharacters(in: .whitespacesAndNewlines),
                        appToken: channel == .slack ? model.draftAppToken.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                    model.connect(credentials)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.draftBotToken.isEmpty || (model.channel == .slack && model.draftAppToken.isEmpty))
            }
        }
    }
    private func credentialField(_ title: String, hint: String, source: String? = nil, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
            SecureField(title, text: text, prompt: Text(hint))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
            if let source { SetupNote(text: title + " · " + source) }
        }
    }
    /// The third step: proof that the private chat is the owner's own, with a fresh expiring code (AC-20.04).
    @ViewBuilder private var pairing: some View {
        if let challenge = model.challenge, let identity = model.identity {
            SetupStep(number: 3, title: "Confirm your private chat") {
                if let link = BotSetupLinks.pairing(identity, challenge: challenge) {
                    if identity.channel == .telegram {
                        SetupNote(text: "Scan with your phone or open Telegram here, then tap Start.")
                        BotPairingQRCode(url: link).frame(maxWidth: .infinity)
                    } else {
                        SetupNote(text: "Send this message to your bot in a direct message:")
                    }
                    if identity.channel == .slack {
                        HStack(spacing: PanelStyle.Space.medium) {
                            Text(verbatim: "lunlet " + challenge.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("lunlet " + challenge.code, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(PanelIconButtonStyle(size: PanelStyle.Layout.inlineButton))
                                .help("Copy pairing message").accessibilityLabel("Copy pairing message")
                        }
                    }
                    Link(identity.channel == .telegram ? "Open Telegram" : "Open Slack", destination: link).font(Font.subheadline)
                } else if identity.channel == .slack {
                    SetupNote(text: "Send this message to your bot in a direct message:")
                    Text(verbatim: "lunlet " + challenge.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                SetupNote(text: "The code expires in 10 minutes.")
            }
        }
    }
}

enum BotSetupLinks {
    static var slackManifest: URL {
        let manifest: [String: Any] = [
            "display_information": ["name": "Lunlet"],
            "features": ["bot_user": ["display_name": "Lunlet", "always_online": false],
                         "app_home": ["messages_tab_enabled": true, "messages_tab_read_only_enabled": false]],
            "oauth_config": ["scopes": ["bot": ["chat:write", "im:history", "users:read"]]],
            "settings": ["socket_mode_enabled": true, "event_subscriptions": ["bot_events": ["message.im"]]]
        ]
        var parts = URLComponents(string: "https://api.slack.com/apps")!
        let json = (try? JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)) ?? Data()
        parts.queryItems = [.init(name: "new_app", value: "1"), .init(name: "manifest_json", value: String(decoding: json, as: UTF8.self))]
        return parts.url!
    }
    static func pairing(_ identity: BotIdentity, challenge: PairingChallenge) -> URL? {
        switch identity.channel {
        case .telegram:
            guard identity.name.range(of: #"\A[A-Za-z0-9_]{1,64}\z"#, options: .regularExpression) != nil else { return nil }
            var parts = URLComponents(string: "https://t.me/" + identity.name)!
            parts.queryItems = [.init(name: "start", value: challenge.code)]
            return parts.url
        case .slack:
            guard let app = identity.applicationID, let team = identity.workspaceID,
                  app.range(of: #"\AA[A-Z0-9]+\z"#, options: .regularExpression) != nil,
                  team.range(of: #"\AT[A-Z0-9]+\z"#, options: .regularExpression) != nil else { return nil }
            var parts = URLComponents(string: "https://slack.com/app_redirect")!
            parts.queryItems = [.init(name: "app", value: app), .init(name: "team", value: team)]
            return parts.url
        }
    }
}

private struct BotPairingQRCode: View {
    private let image: NSImage?
    init(url: URL) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        if let output = filter.outputImage?.transformed(by: .init(scaleX: 6, y: 6)),
           let cg = CIContext().createCGImage(output, from: output.extent) { image = NSImage(cgImage: cg, size: output.extent.size) }
        else { image = nil }
    }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit().padding(6).background(.white) }
        }.frame(width: 104, height: 104).accessibilityLabel("Telegram private pairing QR code")
    }
}
