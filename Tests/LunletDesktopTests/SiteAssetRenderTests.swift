// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.01, AC-28.02, AC-28.04; US-06, AC-06.01, AC-06.02; US-36, AC-36.01, AC-36.03; US-13, AC-13.07.
// Refs: US-19, AC-19.05; US-04, AC-04.13.
// The product page's stills, drawn from the film's synthetic world so every picture is Lunlet's real interface with
// synthetic data (AC-28.02): the Overview open on the synthetic display, the task cue island, the phone's notice on
// Feishu, Slack and Telegram before and after a reply, and the entry in each built-in skin. Opt-in: set `LUNLET_SITE_ASSET_DIR` to a directory
// outside the repository; `scripts/render-site-assets.sh` runs this and places the results. The screen is never captured.
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import LunletCore
@testable import LunletMessaging
@testable import LunletDesktop

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_SITE_ASSET_DIR"] != nil))
@MainActor struct SiteAssetRenderTests {
    /// Stills are drawn at twice the film's pixel density, so their text stays sharp on a high-resolution display.
    private static let density: CGFloat = 2
    /// The panel at reading size, as the film frames it, for the hero and each page.
    private static let reading = FilmShot.top(scale: 1.5)
    /// Moments when one page is fully shown with nothing hovered: Codex once the panel has opened, the Overview after its
    /// tab click and before the pointer reaches the chart, and Claude Code after its click.
    private static let codexTime = 16.0, heroTime = 24.4, claudeTime = 32.0
    /// The first turn's cue island, fully grown, while the camera is in at the notch.
    private static let cueTime = 9.6
    /// Crops in film pixels: the display's top with the panel, and the strip around the notch.
    private static let heroCrop = CGRect(x: 160, y: 0, width: 1600, height: 760)
    private static let cueCrop = CGRect(x: 0, y: 0, width: 1920, height: 240)
    /// Desktop kept around a page's panel, in film points.
    private static let panelMargin: CGFloat = 36

    @Test func renderProductPageStills() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_SITE_ASSET_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let world = try await FilmWorld()
        let film = FilmStoryboard(world: world)
        // The page stills are named after the agents' own identifiers, and every agent the app offers has one.
        let pages: [(String, Double, FilmWorld.Page)] = [(SessionProvider.codex.rawValue, Self.codexTime, .codex),
                                                        ("overview", Self.heroTime, .overview),
                                                        (SessionProvider.claude.rawValue, Self.claudeTime, .claude)]
        #expect(Set(pages.map(\.0)).isSuperset(of: SessionProvider.allCases.map(\.rawValue)))
        for (_, time, page) in pages {
            let shown = film.page(at: time)
            #expect(shown.from == page)
            #expect(shown.amount >= 1)
            #expect(film.panel.progress(time) > 0.99)
            if let overview = film.overviewShown { #expect(time < overview.open || time >= overview.close) }
        }
        #expect(film.cue.visible(Self.cueTime))
        #expect(film.cue.progress(Self.cueTime) > 0.99)

        func still(at time: Double, crop: CGRect, camera: FilmShot? = nil, name: String) async throws {
            let frame = await film.frame(at: time, captions: false, density: Self.density, pointer: false, camera: camera)
            let pixels = crop.applying(CGAffineTransform(scaleX: Self.density, y: Self.density))
            try Self.write(try #require(frame.cropping(to: pixels)), to: directory.appendingPathComponent(name))
        }
        try await still(at: Self.heroTime, crop: Self.heroCrop, name: "hero-overview.png")
        try await still(at: Self.cueTime, crop: Self.cueCrop, name: "cue-island.png")
        // Each page's panel at reading size with the desktop around it, from the display's top edge.
        let panel = world.panelFrame.insetBy(dx: -Self.panelMargin, dy: 0)
        let panelCrop = CGRect(x: Self.reading.origin.x + panel.minX * Self.reading.scale, y: 0,
                               width: panel.width * Self.reading.scale, height: (panel.maxY + Self.panelMargin) * Self.reading.scale)
        for (name, time, _) in pages {
            try await still(at: time, crop: panelCrop.integral, camera: Self.reading, name: "panel-" + name + ".png")
        }
        // The notice on each channel, open, with the reply received, and rewritten as delivered (AC-06.01, AC-06.02,
        // AC-36.01, AC-36.03), each on the film's generic phone. Feishu is the film's card; Slack and Telegram are
        // read back from the messages Lunlet composes for them.
        for (name, screen) in [("phone-feishu-notice", world.phoneChat), ("phone-feishu-replied", world.phoneChatReplied),
                               ("phone-feishu-delivered", world.phoneChatDelivered)] {
            try Self.write(Self.phone(screen), to: directory.appendingPathComponent(name + ".png"))
        }
        // Every messenger the app offers is shown: Feishu as the film's card, the others from their composed messages.
        #expect(Set(CommunicationChannel.allCases.map(\.rawValue)) == ["feishu", "slack", "telegram"])
        let notice = SessionNotice.prepare(world.notice)
        let states: [(String, NoticeReplyState)] = [("notice", .open), ("replied", .received(world.replyText)),
                                                    ("delivered", .finished(.delivered, world.replyText))]
        for (state, reply) in states {
            let slack = try FilmSlackNotice(SlackNoticeMessage.body(notice, channel: "D0SYNTHETIC", reply: reply))
            let telegram = try FilmTelegramNotice(html: TelegramNoticeMessage.html(notice, reply: reply),
                                                  markup: TelegramNoticeMessage.replyMarkup(reply))
            #expect(slack.headerText == "Codex succeeded · lunlet-site")
            #expect(telegram.plainText.hasPrefix("Codex succeeded · lunlet-site"))
            if reply == .open {
                #expect(slack.contextLines.last?.hasPrefix("Reply in this thread") == true)
                #expect(telegram.button == NoticeReplyText.replyButton)
            } else {
                let label = NoticeReplyText.status(reply, agent: "Codex")?.label ?? ""
                #expect(slack.contextLines.last?.hasPrefix(label) == true)
                #expect(telegram.button == nil)
                #expect(telegram.plainText.contains(label))
            }
            let replied = reply == .open ? nil : world.replyText
            let time = reply == .open ? "4:52" : "4:53"
            let slackChat = FilmSlackChat(notice: slack, avatar: world.icon, time: time, stamp: "Today 4:52 PM", reply: replied)
            let telegramChat = FilmTelegramChat(notice: telegram, avatar: world.icon, time: time, stamp: "Today 4:52 PM",
                                                prompt: replied == nil ? nil : NoticeReplyText.prompt(agent: "Codex"), reply: replied)
            try Self.write(Self.phone(await Self.screen(slackChat)), to: directory.appendingPathComponent("phone-slack-" + state + ".png"))
            try Self.write(Self.phone(await Self.screen(telegramChat)), to: directory.appendingPathComponent("phone-telegram-" + state + ".png"))
        }
        // The entry beside the notch in each built-in skin, with the same agents and sessions as the film (AC-04.13).
        for skin in SkinCatalog.builtins {
            try Self.write(try Self.entry(skin: skin, allowances: world.allowances, status: world.sessionStatus),
                           to: directory.appendingPathComponent("notch-" + skin.id + ".png"))
        }
        await world.shutdown()
    }

    /// A y-down drawing context of `size` points at `scale` pixels per point, transparent.
    private static func context(_ size: CGSize, scale: CGFloat) throws -> CGContext {
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.setShouldAntialias(true); context.setAllowsFontSmoothing(true)
        context.translateBy(x: 0, y: size.height * scale); context.scaleBy(x: scale, y: -scale)
        return context
    }

    /// One chat drawn at the phone's screen size and the film's density.
    private static func screen(_ view: some View) async -> CGImage {
        let host = FilmPageHost(AnyView(view), size: FilmPhone.screenSize)
        defer { host.close() }
        return await host.image(pointer: nil)
    }

    /// The phone around one screen image, with room for its shadow.
    private static func phone(_ screen: CGImage) throws -> CGImage {
        let margin: CGFloat = 72, body = FilmPhone.bodySize
        let size = CGSize(width: body.width + 2 * margin, height: body.height + 2 * margin)
        let context = try context(size, scale: density)
        FilmPhone.draw(FilmCanvas(context: context), origin: CGPoint(x: margin, y: margin), scale: 1, alpha: 1) { inner in
            FilmCanvas(context: inner).draw(screen, in: CGRect(origin: .zero, size: FilmPhone.screenSize))
        }
        return try #require(context.makeImage())
    }

    /// The lettering and strands or lanterns beside the hardware notch, resting, on the page's dark ground.
    private static func entry(skin: SkinDefinition, allowances: [AgentAllowance], status: CompactSessionStatus) throws -> CGImage {
        let notch = FilmScreen.notch.size
        let size = VineGeometry(notch: notch).size
        let view = LettermarkView(frame: CGRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .darkAqua)
        view.notchSize = notch
        view.setSkin(skin)
        view.setAllowances(allowances)
        view.setSessionStatus(status)
        view.layoutSubtreeIfNeeded()
        let context = try context(size, scale: 4)
        context.setFillColor(FilmInk.color(0x1c1a23)); context.fill(CGRect(origin: .zero, size: size))
        try #require(view.layer).render(in: context)
        context.addPath(CGPath(roundedRect: CGRect(x: EntryMetrics.wing, y: -12, width: notch.width, height: notch.height + 12),
                               cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
        return try #require(context.makeImage())
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
