// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.02, AC-28.04.
// Refs: US-03, AC-03.05, AC-03.08, AC-03.10; US-13, AC-13.07, AC-13.08, AC-13.09; US-19, AC-19.05.
// Refs: US-04, AC-04.03, AC-04.13; US-32, AC-32.01; US-33, AC-33.09, AC-33.10; US-05, AC-05.06; US-06, AC-06.01, AC-06.02.
// The product film, rendered frame by frame from Lunlet's real views with synthetic data (AC-28.04). Opt-in: set
// `LUNLET_FILM_DIR` to a new directory outside the repository; `scripts/render-film.sh` encodes the frames. The screen is
// never captured, and no account, session, credential or Claude Code configuration on this Mac is read. The whole
// synthetic display frames the close-ups; the ending's phone shows the notice card Lunlet's SessionCard renders.
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import LunletClaude
import LunletCodex
import LunletCore
import LunletFeishu
import LunletMessaging
@testable import LunletDesktop

/// A synthetic 14-inch MacBook display. Lunlet's own placement functions position every surface on it.
enum FilmScreen {
    static let geometry = PanelScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                                      notch: CGRect(x: 663.5, y: 950, width: 185, height: 32))
    static var notch: CGRect { geometry.notch! }
    /// Screen coordinates (y up) as film points around the notch's center, with y pointing down from the top edge.
    static func film(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - notch.midX, y: geometry.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Lunlet's motion constants. Those its sources keep private are restated here with the source that owns them.
enum FilmTiming {
    static let fps = 30.0
    static let expand = FilmSpring(response: NotchSurfaceView.expandResponse)
    static let collapse = FilmSpring(response: NotchSurfaceView.collapseResponse)
    static let expandDuration = NotchSurfaceView.expandDuration
    static let collapseDuration = NotchSurfaceView.collapseDuration
    static let retraction = seconds(NotchSurfaceView.retractionDelay)
    /// NotchSurfaceView.Fade: content fades in after the outline starts opening and out quickly as it closes.
    static let contentDelay = 0.08, contentReveal = 0.18, contentConceal = 0.12
    /// The island content's slide back under the notch uses a spring with the conceal response.
    static let concealSlide = FilmSpring(response: contentConceal)
    /// CompanionPanelController.HoverDelay.open and UsageHoverPanelController.HoverDelay.
    static let panelHover = 0.22, overviewOpen = 0.18, overviewClose = 0.30
    /// A task cue stays this long (AC-13.08).
    static let cueHold = CuePresentation.displayDuration
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// One NotchSurfaceView's motion: `setExpanded(true)` at `opened` and `setExpanded(false)` at `closed`.
struct SurfaceMotion {
    let opened: Double
    let closed: Double?
    func visible(_ t: Double) -> Bool { t >= opened && (closed.map { t < $0 + FilmTiming.retraction } ?? true) }
    /// The outline between the notch (0) and the full surface (1).
    func progress(_ t: Double) -> CGFloat {
        if let closed, t >= closed {
            let start = FilmTiming.expand.value(closed - opened)
            return CGFloat(start * (1 - FilmTiming.collapse.value(t - closed)))
        }
        return CGFloat(FilmTiming.expand.value(t - opened))
    }
    /// The glass, or the island's black fill: an ease-in-out fade.
    func backdrop(_ t: Double) -> CGFloat {
        if let closed, t >= closed {
            let start = Double(backdrop(closed - 1e-6))
            return CGFloat(start * (1 - FilmEasing.evaluate(FilmEasing.easeInOut, (t - closed) / FilmTiming.collapseDuration)))
        }
        return CGFloat(FilmEasing.evaluate(FilmEasing.easeInOut, (t - opened) / FilmTiming.contentReveal))
    }
    /// The hosted content: a linear fade after a short delay, and a quicker one out.
    func content(_ t: Double) -> CGFloat {
        if let closed, t >= closed { return CGFloat(max(0, 1 - (t - closed) / FilmTiming.contentConceal)) }
        return CGFloat(min(1, max(0, (t - opened - FilmTiming.contentDelay) / FilmTiming.contentReveal)))
    }
    /// Island content offset toward the notch, in points.
    @MainActor func slide(_ t: Double) -> CGFloat {
        let distance = Double(NotchSurfaceView.slideDistance)
        if let closed, t >= closed {
            let elapsed = t - closed
            return elapsed > FilmTiming.contentConceal ? 0 : CGFloat(distance * FilmTiming.concealSlide.value(elapsed))
        }
        let elapsed = t - opened - FilmTiming.contentDelay
        return elapsed > FilmTiming.expandDuration ? 0 : CGFloat(distance * (1 - FilmTiming.expand.value(elapsed)))
    }
}

/// An offscreen window that is never ordered onto a display and backs its views at the film's pixel density.
final class FilmWindow: NSWindow {
    override var backingScaleFactor: CGFloat { FilmPageHost.scale }
}

/// One real view in an offscreen window, so text is drawn at the film's density and synthetic pointer events can
/// drive its SwiftUI hover state through the hosting view's own tracking area.
@MainActor final class FilmPageHost {
    nonisolated static let scale: CGFloat = 3
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private var inside = false
    private var cached: (pointer: CGPoint?, image: CGImage)?

    init(_ content: AnyView, size: CGSize) {
        hosting = NSHostingView(rootView: AnyView(content.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = FilmWindow(contentRect: CGRect(origin: CGPoint(x: -40_000, y: -40_000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
    }
    /// The page with the pointer at `pointer` (view points, y down) or outside it.
    func image(pointer: CGPoint?) async -> CGImage {
        let pointer = pointer.map { CGPoint(x: ($0.x * 4).rounded() / 4, y: ($0.y * 4).rounded() / 4) }
        if let cached, cached.pointer == pointer { return cached.image }
        if let pointer {
            let location = CGPoint(x: pointer.x, y: hosting.bounds.height - pointer.y)
            if !inside, let enter = boundaryEvent(.mouseEntered, location) { hosting.mouseEntered(with: enter); inside = true }
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                hosting.mouseMoved(with: moved)
            }
        } else if inside, let exit = boundaryEvent(.mouseExited, .init(x: -10, y: -10)) {
            hosting.mouseExited(with: exit); inside = false
        }
        try? await Task.sleep(for: .milliseconds(20))
        let image = FilmPageHost.snapshot(hosting)
        cached = (pointer, image)
        return image
    }
    private func boundaryEvent(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent? {
        if hosting.trackingAreas.isEmpty { hosting.updateTrackingAreas() }
        guard let area = hosting.trackingAreas.first(where: { $0.owner === hosting }) else { return nil }
        return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0,
                                      trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)
    }
    func close() { window.contentView = nil; window.close() }

    /// A transparent render at the film's pixel density, so text stays sharp through the camera.
    static func snapshot(_ view: NSView, scale: CGFloat = FilmPageHost.scale) -> CGImage {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!.retagging(with: .sRGB)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage!
    }
}

/// Synthetic models behind every real view in the film, and the surfaces placed on the synthetic display.
@MainActor final class FilmWorld {
    enum Page { case codex, overview, claude }
    let desktop: FilmDesktop
    let entry: LettermarkView
    /// The lettering's wake and the strands' flex, as LettermarkView animates them for a cue or a hover.
    let wake: FilmKeyframes
    let entryFrame: CGRect, panelFrame: CGRect, bodyFrame: CGRect, overviewFrame: CGRect, cueFrame: CGRect, startCueFrame: CGRect
    let notch = FilmScreen.film(FilmScreen.notch)
    let cueContent: CGImage, startCueContent: CGImage
    let codexOverview: CGImage
    let icon: CGImage
    /// The desktop with its windows, frosted for the panel's glass.
    let glassBackdrop: CGImage
    /// The menu-bar clock, the lock screen, and the phone's lock screen, notification and bot chat: the notice with its
    /// open reply box, then with the owner's reply received, then rewritten as delivered.
    let clock: String
    let macLock: CGImage, phoneLock: CGImage, phoneBanner: CGImage, phoneChat: CGImage, phoneChatReplied: CGImage, phoneChatDelivered: CGImage
    /// The completion card SessionCard renders for the ending's turn, open and after the reply was delivered.
    let card: FilmNoticeCard, cardDelivered: FilmNoticeCard
    /// What the entry shows: both agents' allowances and the sessions' compact status.
    let allowances: [AgentAllowance], sessionStatus: CompactSessionStatus
    private let hosts: [Page: FilmPageHost]
    private let cleanup: () async -> Void

    init() async throws {
        let geometry = FilmScreen.geometry
        let desktop = FilmDesktop()
        self.desktop = desktop
        let suite = "com.lunlet.test.film.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let skinDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-film-\(UUID())")
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.providers = [.codex, .claude] }
        let skins = SkinCatalog(directory: skinDirectory)
        let now = Date(), epoch = Int(now.timeIntervalSince1970)
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: today)! }

        // Codex: a Pro account with 69% of its week left, credits, two reset credits and its recorded allowance history.
        let codexReset = epoch + 4 * 86_400 + 3 * 3_600
        let account = try AccountLimitsDecoder.decode(Data("""
        {"rateLimits":{"limitId":"codex","secondary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":\(codexReset)},"credits":{"balance":"75000.000000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 3*86400 + 4*3600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 11*86400 + 8*3600)}]}}
        """.utf8), observedAt: now.addingTimeInterval(-120),
            accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8))
        let usage = AccountUsageModel(client: RenderAccount(snapshot: account))
        usage.start()
        let windowStart = Double(codexReset - 7 * 86_400)
        var quota: [LocalQuotaObservation] = []
        // This week's readings since it began, down to 69%.
        for at in stride(from: windowStart + 1_800, to: now.timeIntervalSince1970 - 1_800, by: 3 * 3_600) {
            let progress = (at - windowStart) / (now.timeIntervalSince1970 - windowStart)
            quota.append(.init(at: Date(timeIntervalSince1970: at), resetAt: Date(timeIntervalSince1970: Double(codexReset)),
                               remaining: (100 - 31 * pow(progress, 0.92)).rounded(), bucketID: "codex", plan: "pro"))
        }

        // The first Codex conversation is the one the cues, the panel and the phone notice describe.
        let codexIDs = [FilmStoryboard.noticeSession, UUID(), UUID()], claudeIDs = (0..<3).map { _ in UUID() }
        let codexTokens: [Double] = [42, 58, 76, 49, 64], claudeTokens: [Double] = [24, 37, 19, 45, 31]
        let codexHistory = LocalUsageHistory(days: codexTokens.enumerated().map { index, millions in
            .init(date: day(4 - index), amount: .init(tokens: Int64(millions * 1_000_000), estimatedUSD: millions * 0.67, partial: false))
        }, sessions: Dictionary(uniqueKeysWithValues: zip(codexIDs, [(3.8, 2.6), (12.4, 8.1), (1.2, 0.85)]).map {
            ($0, LocalUsageAmount(tokens: Int64($1.0 * 1_000_000), estimatedUSD: $1.1, partial: false))
        }), partial: false, quotaHistory: quota)
        func breakdown(_ millions: Double) -> LocalTokenBreakdown {
            let total = millions * 1_000_000
            return .init(input: Int64(total * 0.013), output: Int64(total * 0.037), cacheWrite: Int64(total * 0.074),
                         cacheRead: Int64(total * 0.876))
        }
        let claudeHistory = LocalUsageHistory(days: claudeTokens.enumerated().map { index, millions in
            .init(date: day(4 - index), amount: .init(tokens: Int64(millions * 1_000_000), estimatedUSD: millions * 0.68,
                                                       partial: true, breakdown: breakdown(millions)))
        }, sessions: Dictionary(uniqueKeysWithValues: zip(claudeIDs, [6.2, 2.9, 1.1]).map {
            ($0, LocalUsageAmount(tokens: Int64($1 * 1_000_000), estimatedUSD: $1 * 0.69, partial: true, breakdown: breakdown($1)))
        }), partial: true)
        let codexUsage = LocalUsageModel(reader: RenderUsage(history: codexHistory))
        let claudeUsage = LocalUsageModel(reader: RenderUsage(history: claudeHistory))
        codexUsage.refresh(); claudeUsage.refresh()

        // Claude Code: a connected status line in a temporary configuration, never the real one, and a Max 5x profile.
        let fixture = try ClaudeLimitsFixture()
        _ = try fixture.connection.connect()
        try Data(#"{"oauthAccount":{"emailAddress":"synthetic@example.invalid","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_5x"}}"#.utf8)
            .write(to: fixture.connection.home.profile)
        let claudeReset = epoch + 3 * 86_400 + 5 * 3_600, claudeStart = claudeReset - 7 * 86_400
        let log = stride(from: claudeStart + 3_600, to: epoch - 1_800, by: 4 * 3_600).map { at in
            "\(at) \(Int((41 * pow(Double(at - claudeStart) / Double(epoch - claudeStart), 0.95)).rounded())) \(claudeReset)"
        }.joined(separator: "\n") + "\n"
        try fixture.write(state: "lunlet-claude-limits 1\nfive_hour 22 \(epoch + 2 * 3_600 + 1_200) \(epoch - 60)\n"
                          + "seven_day 41 \(claudeReset) \(epoch - 60)\n", log: log)
        let limits = ClaudePlanLimitsModel(service: fixture.connection)
        limits.setActive(true)
        try await ClaudeLimitsFixture.settle(limits) { limits.limits?.sevenDay != nil && limits.account != nil }

        // Sessions: the cue's conversation finished last, so it leads the Codex list.
        let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: RenderCues())
        sessions.setMonitoredProviders([.codex, .claude])
        let rows: [(UUID, SessionProvider, String, String, SessionPhase, Double)] = [
            (codexIDs[0], .codex, "lunlet-site", "Refine the product page", .idle(completedTurnID: "turn-a"), 20),
            (codexIDs[1], .codex, "lunlet", "Add a test for the weekly estimate", .running, 140),
            (codexIDs[2], .codex, "release-notes", "Prepare the release checklist", .approval, 380),
            (claudeIDs[0], .claude, "lunlet", "Summarize the failing UI tests", .running, 70),
            (claudeIDs[1], .claude, "lunlet-site", "Tighten the onboarding copy", .idle(completedTurnID: "turn-b"), 720),
            (claudeIDs[2], .claude, "docs", "Explain the weekly estimate", .idle(completedTurnID: "turn-c"), 2_400),
        ]
        for (id, provider, project, preview, phase, age) in rows {
            sessions.receive(.init(observation: .init(sessionID: id, connectionID: UUID(), liveness: .unverified, phase: phase),
                                   project: project, outcome: .succeeded, turnID: "turn-\(id.uuidString.prefix(6))",
                                   activityConfirmed: true, lastActivityAt: now.addingTimeInterval(-age), localPreview: preview,
                                   provider: provider), origin: .snapshot)
        }
        // Opening right after the cue selects its conversation on its agent's page (AC-13.09).
        sessions.select(codexIDs[0])
        let deadline = ContinuousClock.now + .seconds(3)
        while (codexUsage.snapshot == nil || claudeUsage.snapshot == nil || usage.state == .loading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        // Every surface placed by Lunlet's own placement functions.
        let panelScreen = PanelPlacement.panel(tabRow: true, screen: geometry)
        let bodyScreen = panelScreen.insetBy(dx: NotchSurfaceGeometry.bodyInset(notchWidth: FilmScreen.notch.width), dy: 0)
        let body = FilmScreen.film(bodyScreen), overviewPlacement = FilmScreen.film(UsageHoverPlacement.frame(
            size: UsageHoverPanelController.overviewSize, parent: bodyScreen, visible: geometry.visibleFrame))
        panelFrame = FilmScreen.film(panelScreen); bodyFrame = body; overviewFrame = overviewPlacement
        let entryScreen = try #require(PanelPlacement.entry(screen: geometry))
        entryFrame = FilmScreen.film(entryScreen)
        let band = try #require(PanelPlacement.band(panel: panelScreen, screen: geometry))

        let hover = UsageHoverPanelController(observesSystemEvents: false)
        let claudeHover = UsageHoverPanelController(observesSystemEvents: false)
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: RenderPower())
        let setup = FeishuSetupModel(store: RenderEnrollmentStore())
        let botSetup = BotChannelSetupModel(storeFactory: { _ in RenderCredentialStore() })
        let bodySize = body.size
        func page(_ tab: SessionProvider?) -> FilmPageHost {
            FilmPageHost(AnyView(CompanionPanel(preferences: preferences, skins: skins, setup: setup, botSetup: botSetup,
                                                notifications: notifications, usage: usage, sessions: sessions, history: codexUsage,
                                                usageHover: hover, claudeHistory: claudeUsage, claudeUsageHover: claudeHover,
                                                refresh: {}, openingTab: tab)
                .environment(\.notchBand, band).environment(\.claudePlanLimits, limits)), size: bodySize)
        }
        hosts = [.codex: page(.codex), .overview: page(nil), .claude: page(.claude)]
        // The Codex limits' hover overview, tinted as the runtime tints it.
        let overview = FilmPageHost(AnyView(PanelTinted(preferences: preferences, skins: skins, agent: .codex) {
            UsageOverviewPanel(account: usage, history: codexUsage)
        }), size: overviewPlacement.size)
        try await Task.sleep(for: .milliseconds(40))
        codexOverview = await overview.image(pointer: nil)
        overview.close()

        // The task cue islands, with the real cue content view on the real island geometry: the first turn finishing,
        // then the follow-up starting.
        let connection = UUID().uuidString
        func island(_ cue: TaskCue) async throws -> (CGRect, CGImage) {
            let text = TaskCueText(cue: cue)
            let cueScreen = PanelPlacement.cue(size: text.size(screen: geometry), screen: geometry)
            let surface = TransientCuePanel.surface(text: text, screen: geometry, frame: cueScreen)
            surface.layoutSubtreeIfNeeded()
            let cueView = try #require(surface.subviews.compactMap { $0 as? NSHostingView<AnyView> }.first)
            let cueHost = FilmPageHost(cueView.rootView, size: cueView.frame.size)
            defer { cueHost.close() }
            return (FilmScreen.film(cueScreen), await cueHost.image(pointer: nil))
        }
        let finished = try await island(TaskCue(sessionID: codexIDs[0].uuidString, connectionID: connection, turnID: "turn-a",
                                                title: "lunlet-site", phase: .finished(.succeeded), context: "Refine the product page"))
        let started = try await island(TaskCue(sessionID: codexIDs[0].uuidString, connectionID: connection, turnID: "turn-e",
                                               title: "lunlet-site", phase: .started, context: FilmTerminal.followUp))
        cueFrame = finished.0; cueContent = finished.1
        startCueFrame = started.0; startCueContent = started.1

        // The entry: both agents' strands, the waiting badge, and the motion a cue or hover starts.
        entry = LettermarkView(frame: CGRect(origin: .zero, size: entryFrame.size))
        entry.appearance = NSAppearance(named: .darkAqua)
        entry.notchSize = FilmScreen.notch.size
        allowances = NotchEntryController.allowances(providers: [.codex, .claude], codex: 69, claude: limits.limits,
                                                     claudeConnected: true, now: now)
        sessionStatus = .init(snapshots: sessions.sessions, available: true, partial: false)
        entry.setAllowances(allowances)
        entry.setSessionStatus(sessionStatus)
        entry.layoutSubtreeIfNeeded()
        entry.setActive(true); entry.setPose(.finished, replay: true)
        wake = FilmKeyframes(capturing: try #require(entry.layer))

        let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/assets/branding/lunlet-app-icon.png")
        let source = try #require(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        // The source artwork keeps its presentation background; the film shows only its rounded square.
        let appIcon = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)?.cropping(to: CGRect(x: 108, y: 110, width: 1036, height: 1008)))
        icon = appIcon

        // The desktop around Lunlet, as the panel's glass sees it once the first turn has finished.
        let backdropTime = FilmStoryboard.finishedCue + 1
        glassBackdrop = desktop.backdrop { context in
            let canvas = FilmCanvas(context: context)
            FilmEditor.draw(canvas); FilmTerminal.draw(canvas, at: backdropTime)
        }
        // Synthetic times on the render day: the desktop before locking, the lock, and the phone when the turn finishes.
        let calendarDay = DateFormatter(), longDay = DateFormatter()
        calendarDay.locale = Locale(identifier: "en_US_POSIX"); calendarDay.dateFormat = "EEE MMM d"
        longDay.locale = Locale(identifier: "en_US_POSIX"); longDay.dateFormat = "EEEE, MMMM d"
        clock = calendarDay.string(from: now) + "  4:46 PM"
        func snapshot(_ view: some View, _ size: CGSize) async -> CGImage {
            let host = FilmPageHost(AnyView(view), size: size)
            defer { host.close() }
            return await host.image(pointer: nil)
        }
        macLock = await snapshot(FilmMacLockScreen(wallpaper: desktop.frosted, date: longDay.string(from: now), time: "4:47"),
                                 FilmDesktop.region.size)
        // The phone's wallpaper is a portrait crop of the same generated artwork.
        let portrait = try #require(desktop.wallpaper.cropping(to: CGRect(x: 458, y: 0, width: 907, height: desktop.wallpaper.height)))
        phoneLock = await snapshot(FilmPhoneLockScreen(wallpaper: portrait, date: longDay.string(from: now), time: "4:52"),
                                   FilmPhone.screenSize)
        // The notice for the follow-up turn, exactly as Lunlet renders it for a locked Mac: a terminal Codex session that
        // finished, with its public conclusion and the reply box of one issued capability; then the same card as the
        // reply service rewrites it, received and delivered (AC-05.06, AC-06.01, AC-06.02, AC-08.03, AC-10.02).
        let filmTime = Calendar.current.date(bySettingHour: 16, minute: 52, second: 0, of: now) ?? now
        let notice = SessionSnapshot(observation: .init(sessionID: codexIDs[0], connectionID: UUID(), liveness: .alive,
                                                        phase: .idle(completedTurnID: "turn-e")),
                                     project: "lunlet-site",
                                     publicConclusion: "Fixed the feature list wrapping on narrow windows. The site build passes.",
                                     outcome: .succeeded, turnID: "turn-e", lastActivityAt: filmTime,
                                     localPreview: "Fix the feature list wrapping on narrow windows", provider: .codex)
        let capability = FeishuReplyCapability(token: UUID(), sessionID: codexIDs[0], turnID: "turn-e",
                                               expiresAt: filmTime.addingTimeInterval(600))
        let replyText = "Add a regression test for the wrapping."
        let noticeCard = try FilmNoticeCard(SessionCard.render(notice, reply: capability, replyState: .open, now: filmTime, locale: Locale(identifier: "en_US")))
        let receivedCard = try FilmNoticeCard(SessionCard.render(notice, reply: capability, replyState: .received(replyText), now: filmTime, locale: Locale(identifier: "en_US")))
        let deliveredCard = try FilmNoticeCard(SessionCard.render(notice, reply: capability,
                                                                  replyState: .finished(.delivered, replyText), now: filmTime, locale: Locale(identifier: "en_US")))
        card = noticeCard; cardDelivered = deliveredCard
        phoneBanner = await snapshot(FilmPhoneBanner(title: "Lunlet · Turn finished", detail: noticeCard.title + " · " + noticeCard.subtitle),
                                     FilmPhone.banner.size)
        phoneChat = await snapshot(FilmPhoneChat(card: noticeCard, avatar: appIcon, time: "4:52", stamp: "Today 4:52 PM"),
                                   FilmPhone.screenSize)
        phoneChatReplied = await snapshot(FilmPhoneChat(card: receivedCard, avatar: appIcon, time: "4:53", stamp: "Today 4:52 PM",
                                                        outgoing: replyText), FilmPhone.screenSize)
        phoneChatDelivered = await snapshot(FilmPhoneChat(card: deliveredCard, avatar: appIcon, time: "4:53", stamp: "Today 4:52 PM",
                                                          outgoing: replyText), FilmPhone.screenSize)

        cleanup = {
            hover.shutdown(); claudeHover.shutdown(); sessions.shutdown()
            await codexUsage.shutdown(); await claudeUsage.shutdown(); await usage.shutdown(); await notifications.shutdown()
            await limits.shutdown(); fixture.remove()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: skinDirectory)
        }
    }
    private struct PageKey: Hashable { let page: Page; let x: CGFloat?; let y: CGFloat? }
    /// Every page image the film has drawn, so a moment drawn early is reused rather than drawn again.
    private var drawn: [PageKey: CGImage] = [:]
    func page(_ page: Page, pointer: CGPoint?) async -> CGImage {
        let key = PageKey(page: page, x: pointer?.x, y: pointer?.y)
        if let image = drawn[key] { return image }
        // Pointer positions arrive in film points; the page is placed at the panel body.
        let image = await hosts[page]!.image(pointer: pointer.map { CGPoint(x: $0.x - bodyFrame.minX, y: $0.y - bodyFrame.minY) })
        drawn[key] = image
        return image
    }
    func shutdown() async {
        for host in hosts.values { host.close() }
        entry.setActive(false)
        await cleanup()
    }
}

/// The storyboard: when each surface opens and closes, where the pointer and the camera go, and what the captions
/// say. Hover openings follow from the pointer with Lunlet's own delays rather than from fixed times.
struct FilmStoryboard {
    struct Key { let time: Double; let point: CGPoint }
    struct Caption { let start: Double; let end: Double; let text: String }
    /// The camera moves from the previous shot to `shot` over `duration` seconds from `start`.
    struct Move { let start: Double; let duration: Double; let shot: FilmShot }
    static let duration = 59.0
    /// The conversation the cues, the panel and the phone notice all describe.
    static let noticeSession = UUID(uuidString: "4C7E2A91-5B3D-4F60-9A1E-2D8C6B0F7A53")!
    /// The first turn finishes and its cue appears.
    static let finishedCue = 7.0
    /// The pointer travels from the terminal to the entry.
    static let approach = (start: 13.0, end: 14.3)
    static let pageClicks: [(time: Double, page: FilmWorld.Page)] = [(23.4, .overview), (30.1, .claude)]
    /// A click outside the panel folds it back.
    static let fold = 34.6
    /// The follow-up: a click in the terminal, the prompt typed and sent, and its start cue.
    static let terminalClick = 36.2
    static let typing = (start: 36.55, end: 38.0)
    static let submit = 38.2
    static let startedCue = 38.4
    /// The Mac locks, then its display sleeps; the phone arrives, wakes with the notice, and opens the bot chat.
    static let lock = 40.6, sleep = 42.8
    static let phoneIn = 43.6, phoneWake = 44.6, banner = 44.85, tap = 47.6, chat = 47.75
    /// The owner's reply leaves the card's box, and the card is rewritten as delivered while the Mac runs it.
    static let reply = 52.9, delivered = 54.7
    static let titleStart = 56.4, titleFade = 0.8
    /// The whole display with the panel open.
    static let poster = 16.0
    static let opening = FilmShot.whole()
    /// The dark Mac to the right, leaving room for the phone in front of it on the left.
    static let ending = FilmShot.whole(scale: 0.84, centerX: 1215)
    /// Large enough to read, and clear of a one-line caption.
    static let phoneOrigin = CGPoint(x: 176, y: 38), phoneScale: CGFloat = 1.02
    static let moves: [Move] = [
        .init(start: 3.8, duration: 1.2, shot: .top(scale: 3)),     // in to the notch for the cue
        .init(start: 12.0, duration: 1.1, shot: .whole()),          // back out as the cue retracts
        .init(start: 16.9, duration: 1.1, shot: .top(scale: 1.5)),  // in to read the panel
        .init(start: 34.8, duration: 1.1, shot: .whole()),          // out as it folds back
        .init(start: 42.9, duration: 1.2, shot: ending),            // aside for the phone
    ]
    static let captions: [Caption] = [
        .init(start: 0.6, end: 3.6, text: "Lunlet sits beside your Mac's notch while your coding agents work."),
        .init(start: 4.3, end: 6.8, text: "Each vine strand shows one agent's weekly allowance left."),
        .init(start: 7.4, end: 11.8, text: "When a turn starts or finishes, a short island grows from the notch."),
        .init(start: 13.2, end: 17.0, text: "Open the panel right after, and it shows that conversation."),
        .init(start: 18.6, end: 22.6, text: "Hover the limits for the weekly trend, an estimate range and daily usage."),
        .init(start: 23.6, end: 26.7, text: "The Overview keeps each agent's limits apart and adds up recorded usage."),
        .init(start: 26.8, end: 30.0, text: "Hover a day for each agent's tokens. Cost is an API-price estimate, never a bill."),
        .init(start: 30.3, end: 34.4, text: "Claude Code shows its session and weekly limits, today's tokens and its sessions."),
        .init(start: 34.8, end: 37.2, text: "Click anywhere else, and it folds back into the notch."),
        .init(start: 37.8, end: 40.4, text: "Send the next prompt, and the island shows the new turn has started."),
        .init(start: 40.9, end: 43.5, text: "Lock your Mac and step away while the turn keeps running."),
        .init(start: 44.9, end: 47.5, text: "When it finishes, Lunlet sends a short notice to your own Feishu, Slack or Telegram bot."),
        .init(start: 48.4, end: 52.2, text: "The notice names the project, the agent and the session, with a summary and a reply box."),
        .init(start: 52.6, end: 56.3, text: "One reply from your phone continues that same session. Approvals always stay on your Mac."),
    ]
    /// The closing title, shown on screen rather than as a burned-in caption.
    static let titleCaption = Caption(start: 57.2, end: duration, text: "Lunlet — A little closer to your flow")

    let world: FilmWorld
    let keys: [Key]
    let cue: SurfaceMotion
    let startCue: SurfaceMotion
    let panel: SurfaceMotion
    let hoverStart: Double
    let overviewShown: (open: Double, close: Double)?

    @MainActor init(world: FilmWorld) {
        self.world = world
        let body = world.bodyFrame
        // Tab centers on the real tab row below the notch band, and a day near the middle of the Overview chart.
        let tabY = body.minY + FilmScreen.notch.height + PanelStyle.Layout.headerHeight / 2
        let overviewTab = CGPoint(x: body.minX + 46, y: tabY), claudeTab = CGPoint(x: body.minX + 205, y: tabY)
        let limitsMeter = CGPoint(x: body.midX + 78, y: body.minY + 152)
        let bar = CGPoint(x: body.midX + 4, y: body.minY + 322)
        let resting = CGPoint(x: 420, y: 640), entry = CGPoint(x: 24, y: 41), outside = CGPoint(x: body.maxX + 80, y: 210)
        let keys: [Key] = [
            .init(time: 0, point: resting), .init(time: Self.approach.start, point: resting),
            .init(time: Self.approach.end, point: entry), .init(time: 17.9, point: entry),
            .init(time: 18.6, point: limitsMeter), .init(time: 22.4, point: limitsMeter),
            .init(time: 23.15, point: overviewTab), .init(time: 24.8, point: overviewTab),
            .init(time: 25.8, point: bar), .init(time: 29.2, point: bar),
            .init(time: 29.9, point: claudeTab), .init(time: 33.2, point: claudeTab),
            .init(time: 33.8, point: .init(x: body.maxX + 60, y: tabY)), .init(time: 34.35, point: outside),
            .init(time: 35.2, point: outside), .init(time: 36.0, point: FilmTerminal.composer),
        ]
        self.keys = keys
        cue = SurfaceMotion(opened: Self.finishedCue, closed: Self.finishedCue + FilmTiming.cueHold)
        // A locked display presents no cue, so the start cue leaves when the Mac locks.
        startCue = SurfaceMotion(opened: Self.startedCue, closed: min(Self.startedCue + FilmTiming.cueHold, Self.lock))
        // The panel opens once the pointer has rested in the entry for the hover delay (AC-03.08).
        let sample = stride(from: Self.approach.start, through: Self.approach.end, by: 1.0 / 600)
        let entered = sample.first { world.entryFrame.contains(Self.pointer(keys, at: $0)) } ?? Self.approach.end
        hoverStart = entered
        let panel = SurfaceMotion(opened: entered + FilmTiming.panelHover, closed: Self.fold)
        self.panel = panel
        // The Codex limits group opens its overview after its own delay and closes after its grace period (AC-04.08).
        let anchor = CGRect(x: body.minX + 24, y: body.minY + 124, width: body.width - 48, height: 52)
        let window = stride(from: panel.opened, to: Self.pageClicks[0].time, by: 1.0 / 600).map { ($0, anchor.contains(Self.pointer(keys, at: $0))) }
        if let enter = window.first(where: { $0.1 })?.0,
           let leave = window.first(where: { $0.0 > enter && !$0.1 })?.0 {
            overviewShown = (enter + FilmTiming.overviewOpen, leave + FilmTiming.overviewClose)
        } else { overviewShown = nil }
    }

    /// The pointer glides between keys on a slight arc.
    static func pointer(_ keys: [Key], at t: Double) -> CGPoint {
        guard let next = keys.firstIndex(where: { $0.time > t }) else { return keys.last!.point }
        guard next > 0 else { return keys[0].point }
        let a = keys[next - 1], b = keys[next]
        let s = FilmEasing.smooth((t - a.time) / (b.time - a.time))
        let dx = b.point.x - a.point.x, dy = b.point.y - a.point.y, length = max(1, hypot(dx, dy))
        let bow = min(40, 0.08 * length) * CGFloat(sin(Double.pi * s))
        return CGPoint(x: a.point.x + dx * CGFloat(s) - dy / length * bow, y: a.point.y + dy * CGFloat(s) + dx / length * bow)
    }
    func pointer(at t: Double) -> CGPoint { Self.pointer(keys, at: t) }

    /// The camera: the whole display, the notch close up, the panel at reading size, and the Mac set aside for the phone.
    func camera(at t: Double) -> FilmShot {
        var current = Self.opening
        for move in Self.moves where t >= move.start {
            let amount = (t - move.start) / move.duration
            if amount < 1 { return FilmShot.blend(current, move.shot, FilmEasing.smooth(amount)) }
            current = move.shot
        }
        return current
    }
    func page(at t: Double) -> (from: FilmWorld.Page, to: FilmWorld.Page, amount: CGFloat) {
        var current = FilmWorld.Page.codex
        for click in Self.pageClicks where click.time <= t {
            let amount = CGFloat(min(1, (t - click.time) / 0.12))
            if amount < 1 { return (current, click.page, amount) }
            current = click.page
        }
        return (current, current, 1)
    }
    func press(at t: Double) -> (press: CGFloat, ring: CGFloat?) {
        for time in Self.pageClicks.map(\.time) + [Self.fold, Self.terminalClick] {
            let elapsed = t - time
            if elapsed > -0.08, elapsed < 0.45 {
                let press = CGFloat(max(0, 1 - abs(elapsed - 0.02) / 0.1))
                return (press, elapsed >= 0 ? CGFloat(elapsed / 0.45) : nil)
            }
        }
        return (0, nil)
    }
    func captionText(at t: Double) -> (String, CGFloat)? {
        guard let caption = Self.captions.first(where: { t >= $0.start - 0.25 && t < $0.end + 0.25 }) else { return nil }
        let fade = min(1, (t - (caption.start - 0.25)) / 0.25, ((caption.end + 0.25) - t) / 0.25)
        return (caption.text, CGFloat(max(0, fade)))
    }

    /// The panel pages shown at `t`, with the pointer when it is over them; macOS hides the pointer while typing, and it
    /// does not return before the Mac locks. A still without the pointer shows no hover state either.
    @MainActor func pages(at t: Double, hover: Bool = true) async -> (from: CGImage?, to: CGImage?) {
        guard panel.visible(t) else { return (nil, nil) }
        let pointer = pointer(at: t), state = page(at: t)
        let hovering = hover && t < Self.typing.start && world.bodyFrame.contains(pointer) ? pointer : nil
        let from = await world.page(state.from, pointer: hovering)
        return (from, state.amount < 1 ? await world.page(state.to, pointer: hovering) : nil)
    }

    /// One frame. Stills for the product page pass a higher `density`, hide the pointer and may fix the `camera`.
    @MainActor func frame(at t: Double, captions: Bool = true, density: CGFloat = 1, pointer showPointer: Bool = true,
                          camera shot: FilmShot? = nil) async -> CGImage {
        let canvas = FilmCanvas(density: density)
        let context = canvas.context
        let pointer = pointer(at: t)
        let pointerOnScreen = showPointer && t < Self.typing.start
        let panelVisible = panel.visible(t)
        let state = page(at: t)
        let (from, to) = await pages(at: t, hover: showPointer)
        let locked = CGFloat(FilmEasing.smooth((t - Self.lock) / 0.35))
        let asleep = CGFloat(FilmEasing.smooth((t - Self.sleep) / 1.0))

        FilmDevice.backdrop(context)
        canvas.camera(shot ?? camera(at: t)) {
            FilmDevice.drawLid(canvas)
            context.saveGState(); context.addPath(FilmDevice.screen); context.clip()
            if locked < 1 { drawDesktop(canvas, at: t, panelVisible: panelVisible, from: from, to: to, state: state) }
            if locked > 0 {
                canvas.draw(world.macLock, in: FilmDesktop.region, alpha: locked)
                FilmMenuBar.status(context, clock: nil, alpha: locked)
            }
            FilmDevice.drawSleep(context, amount: asleep)
            context.restoreGState()

            // The hardware notch covers everything beneath it.
            let notch = world.notch
            context.addPath(CGPath(roundedRect: CGRect(x: notch.minX, y: notch.minY - 12, width: notch.width, height: notch.height + 12),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()

            if pointerOnScreen {
                let click = press(at: t)
                FilmArt.pointer(canvas, at: pointer, press: click.press, ring: click.ring)
            }
        }
        drawPhone(canvas, at: t)

        let title = CGFloat(FilmEasing.smooth((t - Self.titleStart) / Self.titleFade))
        if title > 0 {
            context.saveGState(); context.setAlpha(title); context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawTitle(canvas)
            context.endTransparencyLayer(); context.restoreGState()
        }
        if captions, let (text, opacity) = captionText(at: t) { FilmArt.caption(canvas, text, opacity: opacity) }
        if t < 0.6 {
            context.setFillColor(CGColor(gray: 0, alpha: CGFloat(1 - FilmEasing.smooth(t / 0.6))))
            context.fill(CGRect(origin: .zero, size: FilmCanvas.size))
        }
        return context.makeImage()!
    }

    /// The unlocked desktop in film points: wallpaper, menu bar, windows, then Lunlet's cue, panel and entry above them.
    @MainActor private func drawDesktop(_ canvas: FilmCanvas, at t: Double, panelVisible: Bool, from: CGImage?, to: CGImage?,
                                        state: (from: FilmWorld.Page, to: FilmWorld.Page, amount: CGFloat)) {
        let context = canvas.context
        canvas.draw(world.desktop.wallpaper, in: FilmDesktop.region)
        FilmMenuBar.draw(context, clock: world.clock)
        FilmEditor.draw(canvas)
        FilmTerminal.draw(canvas, at: t)

        for (motion, frame, content) in [(cue, world.cueFrame, world.cueContent), (startCue, world.startCueFrame, world.startCueContent)]
        where motion.visible(t) {
            let outline = NotchSurfaceGeometry.island(size: frame.size, notchWidth: FilmScreen.notch.width,
                                                      notchHeight: FilmScreen.notch.height, progress: motion.progress(t),
                                                      notchCenter: world.notch.midX - frame.minX)
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: frame.minX, ty: frame.maxY)
            let path = outline.copy(using: &flip)!
            context.saveGState(); context.addPath(path); context.clip()
            context.setFillColor(CGColor(gray: 0, alpha: motion.backdrop(t))); context.fill(frame)
            canvas.draw(content, in: frame.offsetBy(dx: 0, dy: -motion.slide(t)), alpha: motion.content(t))
            context.restoreGState()
        }

        if panelVisible, let from {
            let frame = world.panelFrame
            let outline = NotchSurfaceGeometry.path(size: frame.size, notchWidth: FilmScreen.notch.width,
                                                    notchHeight: FilmScreen.notch.height, progress: panel.progress(t),
                                                    notchCenter: world.notch.midX - frame.minX)
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: frame.minX, ty: frame.maxY)
            let path = outline.copy(using: &flip)!
            canvas.shadow(path, opacity: 0.5 * panel.backdrop(t), radius: 22, offset: 8)
            canvas.glass(path, backdrop: world.glassBackdrop, opacity: panel.backdrop(t))
            context.saveGState(); context.addPath(path); context.clip()
            context.setAlpha(panel.content(t))
            if let to { canvas.crossfade(from, to, amount: state.amount, in: world.bodyFrame) }
            else { canvas.draw(from, in: world.bodyFrame) }
            context.restoreGState()
            if let shown = overviewShown, t >= shown.open, t < shown.close, state.from == .codex, state.amount >= 1 {
                let rounded = RoundedRectangle(cornerRadius: PanelStyle.Radius.surface, style: .continuous)
                    .path(in: world.overviewFrame).cgPath
                canvas.shadow(rounded, opacity: 0.45, radius: 18, offset: 6)
                canvas.glass(rounded, backdrop: world.glassBackdrop, opacity: 1)
                context.saveGState(); context.addPath(rounded); context.clip()
                canvas.draw(world.codexOverview, in: world.overviewFrame)
                context.restoreGState()
            }
        }

        // The entry window sits above the cue and the panel; its vine hides while the panel is shown.
        let motions = [Self.finishedCue, hoverStart, Self.startedCue].filter { t >= $0 }
        world.wake.apply(at: motions.last.map { t - $0 } ?? -1)
        world.entry.setDetailsVisible(panelVisible)
        context.saveGState()
        context.translateBy(x: world.entryFrame.minX, y: world.entryFrame.minY)
        world.entry.layer?.render(in: context)
        context.restoreGState()
    }

    /// The phone in front of the sleeping Mac: it slides in dark, wakes with the notification, and a tap opens the chat.
    @MainActor private func drawPhone(_ canvas: FilmCanvas, at t: Double) {
        guard t >= Self.phoneIn else { return }
        let arrive = CGFloat(FilmEasing.smooth((t - Self.phoneIn) / 0.8))
        let origin = CGPoint(x: Self.phoneOrigin.x - 620 * (1 - arrive), y: Self.phoneOrigin.y)
        FilmPhone.draw(canvas, origin: origin, scale: Self.phoneScale, alpha: min(1, arrive * 1.6)) { context in
            let inner = FilmCanvas(context: context)
            let screen = CGRect(origin: .zero, size: FilmPhone.screenSize), banner = FilmPhone.banner
            inner.draw(world.phoneLock, in: screen, alpha: CGFloat(FilmEasing.smooth((t - Self.phoneWake) / 0.3)))
            if t >= Self.banner, t < Self.chat + 0.5 {
                let pop = CGFloat(FilmEasing.smooth((t - Self.banner) / 0.45)), scale = 0.94 + 0.06 * pop
                let rect = CGRect(x: banner.midX - banner.width * scale / 2, y: banner.midY - banner.height * scale / 2 + 14 * (1 - pop),
                                  width: banner.width * scale, height: banner.height * scale)
                inner.draw(world.phoneBanner, in: rect, alpha: pop)
                let touch = t - Self.tap
                if touch >= 0, touch < 0.4 {
                    let k = CGFloat(touch / 0.4), radius = 16 + 16 * k
                    context.setFillColor(CGColor(gray: 1, alpha: 0.22 * (1 - k)))
                    context.fillEllipse(in: CGRect(x: banner.midX - radius, y: banner.midY - radius, width: 2 * radius, height: 2 * radius))
                }
            }
            if t >= Self.chat {
                // The app opens out of the notification.
                let open = CGFloat(FilmEasing.smooth((t - Self.chat) / 0.45)), scale = 0.3 + 0.7 * open
                let center = CGPoint(x: banner.midX + (screen.midX - banner.midX) * open, y: banner.midY + (screen.midY - banner.midY) * open)
                let rect = CGRect(x: center.x - screen.width * scale / 2, y: center.y - screen.height * scale / 2,
                                  width: screen.width * scale, height: screen.height * scale)
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 24 + 26 * open, cornerHeight: 24 + 26 * open, transform: nil))
                context.clip()
                inner.draw(world.phoneChat, in: rect, alpha: min(1, open * 2.5))
                // The reply is sent and the card rewritten in place: each later state fades in over the one before.
                if t >= Self.reply { inner.draw(world.phoneChatReplied, in: rect, alpha: CGFloat(FilmEasing.smooth((t - Self.reply) / 0.35))) }
                if t >= Self.delivered { inner.draw(world.phoneChatDelivered, in: rect, alpha: CGFloat(FilmEasing.smooth((t - Self.delivered) / 0.35))) }
                context.restoreGState()
            }
        }
    }

    @MainActor private func drawTitle(_ canvas: FilmCanvas) {
        let context = canvas.context
        let full = CGRect(origin: .zero, size: FilmCanvas.size)
        // The frosted desktop, filling the frame.
        let region = FilmDesktop.region, fill = max(full.width / region.width, full.height / region.height)
        let width = region.width * fill, height = region.height * fill
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.08, blue: 0.16, alpha: 1)); context.fill(full)
        canvas.draw(world.desktop.frosted, in: CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.06, green: 0.05, blue: 0.1, alpha: 0.42)); context.fill(full)
        let iconRect = CGRect(x: full.midX - 130, y: 236, width: 260, height: 253)
        let iconShape = RoundedRectangle(cornerRadius: 58, style: .continuous).path(in: iconRect).cgPath
        canvas.shadow(iconShape, opacity: 0.4, radius: 24, offset: 10)
        context.saveGState(); context.addPath(iconShape); context.clip()
        canvas.draw(world.icon, in: iconRect)
        context.restoreGState()
        FilmArt.text(canvas, "Lunlet", font: .systemFont(ofSize: 84, weight: .semibold), color: .white, centerX: full.midX,
                     top: 520, maxWidth: 1600)
        FilmArt.text(canvas, "A little closer to your flow", font: .systemFont(ofSize: 40, weight: .regular),
                     color: CGColor(gray: 1, alpha: 0.78), centerX: full.midX, top: 640, maxWidth: 1600)
    }

    /// WebVTT captions with the same text and timing as the burned-in ones, plus the closing title.
    static var webVTT: String {
        func stamp(_ t: Double) -> String {
            let millis = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
        }
        return "WEBVTT\n\nNOTE\nSPDX-FileCopyrightText: 2026 yukunlabs\nSPDX-License-Identifier: 0BSD\n\n" + (captions + [titleCaption]).map { stamp($0.start) + " --> " + stamp($0.end) + "\n" + $0.text + "\n" }
            .joined(separator: "\n")
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_FILM_DIR"] != nil))
@MainActor struct ProductFilmRenderTests {
    @Test func renderProductFilmFrames() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_FILM_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let world = try await FilmWorld()
        let film = FilmStoryboard(world: world)
        // The cue, panel and overview all open within the film, in the order the storyboard describes.
        #expect(film.panel.opened > film.cue.closed! + FilmTiming.retraction)
        #expect(film.panel.opened - film.cue.closed! < 15)  // AC-13.09: the panel opens on the cue's conversation.
        #expect(film.overviewShown != nil)
        // The panel first opens on the whole display, so its size and place on the screen are clear.
        #expect(film.camera(at: film.panel.opened) == FilmStoryboard.opening)
        #expect(film.camera(at: FilmStoryboard.poster) == FilmStoryboard.opening)
        // The follow-up starts while the Mac is unlocked; its notice is sent only after the Mac locks (AC-05.06).
        #expect(FilmStoryboard.startedCue < FilmStoryboard.lock && FilmStoryboard.lock < FilmStoryboard.banner)
        // The phone shows SessionCard's own card: the agent and the event, the project and session, the request, the
        // reply and an open reply box; after the reply it carries the sent text and the delivered state (AC-06.01,
        // AC-06.02, AC-08.03). The reply is sent and delivered within the film, before the closing title.
        #expect(world.card.title == "Codex succeeded" && world.card.subtitle.hasPrefix("lunlet-site"))
        #expect(world.card.input?.enabled == true && world.card.input?.text == nil && world.card.tag == nil && world.card.status.isEmpty)
        #expect(world.card.paragraphs.contains("You asked") && world.card.paragraphs.contains("Codex"))
        #expect(world.cardDelivered.tag == "Replied" && world.cardDelivered.input?.enabled == false)
        #expect(world.cardDelivered.input?.text == "Add a regression test for the wrapping.")
        #expect(world.cardDelivered.status.first?.hasPrefix("Delivered") == true)
        #expect(FilmStoryboard.chat < FilmStoryboard.reply && FilmStoryboard.reply < FilmStoryboard.delivered
                && FilmStoryboard.delivered < FilmStoryboard.titleStart)
        // `LUNLET_FILM_TIMES` (seconds, comma-separated) renders only those moments for review.
        if let times = ProcessInfo.processInfo.environment["LUNLET_FILM_TIMES"] {
            for time in times.split(separator: ",").compactMap({ Double($0) }) {
                try Self.write(await film.frame(at: time), to: directory.appendingPathComponent(String(format: "t%06.2f.png", time)))
            }
            await world.shutdown(); return
        }
        let count = Int((FilmStoryboard.duration * FilmTiming.fps).rounded())
        // The panel's relative times ("now", "2m") refresh once a minute of wall-clock time, and drawing every frame takes
        // longer than that. Each page is therefore drawn first, in film order and within seconds of appearing, so the
        // film and its poster show the same times throughout.
        for index in 0..<count { _ = await film.pages(at: Double(index) / FilmTiming.fps) }
        for index in 0..<count {
            let image = await film.frame(at: Double(index) / FilmTiming.fps)
            try Self.write(image, to: directory.appendingPathComponent(String(format: "frame-%05d.png", index + 1)))
        }
        try Self.write(await film.frame(at: FilmStoryboard.poster, captions: false), to: directory.appendingPathComponent("poster.png"))
        try Data(FilmStoryboard.webVTT.utf8).write(to: directory.appendingPathComponent("lunlet-captions.vtt"))
        await world.shutdown()
    }
    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
