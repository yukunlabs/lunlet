// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.02, AC-01.03, AC-01.04, AC-01.06, AC-01.07, AC-01.08; US-12, AC-12.02.
// Refs: US-22, AC-22.02, AC-22.03.
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import LunletFeishu

struct FeishuSetupPanel: View {
    @ObservedObject var setup: FeishuSetupModel
    @ObservedObject var notifications: LockedCompletionNotifications
    @ViewBuilder var body: some View {
        switch setup.state {
        case .loading:
            ProgressView("Reading saved connection…").controlSize(.small)
        case .signingRequired:
            SetupAlert(text: "Install a certificate-signed build to connect Feishu.", tone: .attention)
        case .disconnected:
            SetupStep(number: 1, title: "Authorize in Feishu") {
                SetupNote(text: "Lunlet shows a QR code. Scan it with Feishu to create a bot for Lunlet or choose one you already "
                    + "have; the bot then messages only you.")
                HStack {
                    Spacer()
                    Button("Show QR code", action: setup.connect).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        case .requestingCode:
            HStack {
                ProgressView("Preparing QR code and link…").controlSize(.small)
                Spacer()
                Button("Cancel", action: setup.removeSetup).controlSize(.small)
            }
        case .stopping:
            ProgressView("Removing local connection…").controlSize(.small)
        case .saving:
            HStack {
                ProgressView("Saving authorization…").controlSize(.small)
                Spacer()
                Button("Cancel", action: setup.removeSetup).controlSize(.small)
            }
        case .awaitingScan(let code):
            SetupStep(number: 2, title: "Scan with Feishu") {
                SetupNote(text: "Choose an existing bot or create one. Lunlet saves the authorization once Feishu confirms it.")
                RegistrationQRCode(code: code).frame(maxWidth: .infinity)
                HStack {
                    Link("Open in browser", destination: code.verificationURL).font(Font.subheadline)
                    Spacer()
                    Button("Cancel", action: setup.removeSetup).controlSize(.small)
                }
            }
        case .enrolled:
            HStack {
                RemoveSetupButton(title: "Disconnect", setup: setup)
                Spacer()
                Button("Check authorization", action: setup.checkAuthorization).controlSize(.small)
                    .disabled(notifications.authorizationCheck == .checking)
            }
            if ![.notChecked, .unavailable].contains(notifications.authorizationCheck) {
                SetupNote(text: notifications.authorizationCheck.explanation)
            }
        case .failed(let message):
            // What to do next is the card's one prominent line: a Keychain prompt to accept, or a failure to retry.
            SetupAlert(text: message, tone: setup.accessRequired ? .attention : .failure)
            HStack {
                // Removal stays available to an owner who declines Keychain access, but as a quiet action behind a
                // confirmation rather than a peer of Authorize access, which is easy to click by mistake.
                RemoveSetupButton(title: "Remove local setup", setup: setup)
                Spacer()
                Button(setup.retryTitle, action: setup.retry).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}

/// Removal forgets the saved connection, and connecting again creates another Feishu bot, so it asks first.
private struct RemoveSetupButton: View {
    let title: String
    @ObservedObject var setup: FeishuSetupModel

    var body: some View {
        Button(title, role: .destructive) { setup.confirmingRemoval = true }.buttonStyle(.borderless).controlSize(.small)
            .confirmationDialog("Remove the saved Feishu connection?", isPresented: $setup.confirmingRemoval, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: setup.removeSetup)
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Lunlet forgets this connection. Connecting again creates another Feishu bot.")
            }
    }
}

private struct RegistrationQRCode: View {
    private let image: NSImage?

    init(code: RegistrationCode) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.verificationURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
           let cgImage = CIContext().createCGImage(output, from: output.extent) {
            image = NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
        } else {
            image = nil
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .padding(6).background(.white)
                    .accessibilityLabel("Feishu authorization QR code")
            } else {
                Text("Use the authorization link below.").font(Font.caption)
            }
        }
        .frame(width: 112, height: 112)
    }
}
