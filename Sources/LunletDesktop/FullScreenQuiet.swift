// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-42, AC-42.01, AC-42.02, AC-42.03, AC-42.04.
import AppKit

/// Whether the notch entry leaves with the menu bar in another application's full screen (AC-42.03).
enum FullScreenPolicy: String, Codable, CaseIterable, Sendable {
    case menuBar, never
    var title: String {
        switch self { case .menuBar: "With the menu bar"; case .never: "Never" }
    }
}

/// A window as the window server lists it: its owner, its layer and its frame in the server's top-left coordinates.
struct ScreenWindow: Equatable {
    let pid: pid_t
    let layer: Int
    let frame: CGRect
}

/// What the windows on a display say about full screen. Only public facts are read: frames and owners of windows,
/// never their titles or contents.
enum FullScreenScene {
    /// The application whose window covers `display`, the menu bar's strip included, or nil; `windows` are front
    /// to back. No ordinary window reaches over that strip. Not every full-screen window does either: a browser
    /// keeps its own below it, so the kind of Space in front is asked as well (`FullScreenQuiet.fullScreenSpaces`).
    static func owner(of display: CGRect, windows: [ScreenWindow]) -> pid_t? {
        var front: pid_t?
        for window in windows where window.layer == 0 && window.frame.intersects(display) {
            // Another application's window in front means the covering window is not what is being looked at; the
            // application's own sheet or controls in front of it change nothing.
            if let front, front != window.pid { return nil }
            if window.frame.insetBy(dx: -1, dy: -1).contains(display) { return window.pid }
            front = window.pid
        }
        return nil
    }
}

/// Tells every part of Lunlet whether its entry is away from a display that is in another application's full
/// screen, from one reading of the system. A display is in full screen when the Space in front on it is a
/// full-screen one or a window covers it whole; its menu bar is down from the moment the pointer reaches the top
/// edge until the pointer leaves the strip. The system announces none of this, so it is read on a pace while the
/// display is awake and the Mac is in use, and only now and then while it is left alone (AC-42.04).
@MainActor final class FullScreenQuiet {
    static let shared = FullScreenQuiet()
    static let didChange = Notification.Name("com.lunlet.fullScreenQuietChanged")
    /// The move into full screen lasts about half a second and shows the window that will cover the display from
    /// its start; a reading inside it lets the entry leave with the desktop instead of arriving in full screen.
    static let pace: TimeInterval = 0.25
    /// Full screen begins and ends, and the pointer calls the menu bar, by the keyboard or the pointer. The pace
    /// keeps reading for `rest` seconds after either was last touched, since a move out of full screen can end a
    /// moment after the key that began it; after that one reading every `leftAlonePace` seconds is enough for what
    /// an application does by itself, such as leaving full screen when a film ends.
    static let rest: TimeInterval = 3
    static let leftAlonePace: TimeInterval = 3
    /// The pointer calls the menu bar down within `edge` points of the top of the display, and keeps it down within
    /// `strip` points: the bar's own height and the little by which the entry reaches below it.
    static let edge: CGFloat = 2
    static let strip: CGFloat = 60

    /// How the entry in use treats another application's full screen: the notch and menu-bar entries leave and
    /// return with the menu bar, the notch entry stays when that is its saved choice (AC-42.03), and the pet, which
    /// is no part of the menu bar, leaves until the desktop is back (AC-39.02).
    enum Leave: Equatable { case never, withMenuBar, always }
    var leave = Leave.withMenuBar {
        didSet { if leave != oldValue { refresh(); schedule() } }
    }
    static func leave(for entry: EntryPresentation, choice: FullScreenPolicy) -> Leave {
        switch entry {
        case .pet: .always
        case .notch: choice == .never ? .never : .withMenuBar
        case .menuBar: .withMenuBar
        }
    }
    var changed: (() -> Void)?
    private var quiet: Set<CGDirectDisplayID> = []
    /// The full-screen displays whose menu bar the pointer has called down.
    private var peeking: Set<CGDirectDisplayID> = []
    private let windows: () -> [ScreenWindow]
    private let spaces: () -> Set<CGDirectDisplayID>
    private let pointer: () -> CGPoint
    private let barStays: () -> Bool
    private let displays: () -> [CGDirectDisplayID: CGRect]
    private let idle: () -> TimeInterval
    private let uptime: () -> TimeInterval
    private var lastRead: TimeInterval?
    private var observations: [NotificationObservation] = []
    private var timer: Timer?
    private var asleep = false

    init(windows: @escaping () -> [ScreenWindow] = FullScreenQuiet.onScreenWindows,
         spaces: @escaping () -> Set<CGDirectDisplayID> = FullScreenQuiet.fullScreenSpaces,
         pointer: @escaping () -> CGPoint = FullScreenQuiet.pointerLocation,
         barStays: @escaping () -> Bool = FullScreenQuiet.menuBarStaysInFullScreen,
         displays: @escaping () -> [CGDirectDisplayID: CGRect] = FullScreenQuiet.activeDisplays,
         idle: @escaping () -> TimeInterval = FullScreenQuiet.sinceLastInput,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.windows = windows; self.spaces = spaces; self.pointer = pointer; self.barStays = barStays
        self.displays = displays; self.idle = idle; self.uptime = uptime
    }

    func isQuiet(display: CGDirectDisplayID) -> Bool { quiet.contains(display) }
    func isQuiet(_ screen: NSScreen?) -> Bool {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return isQuiet(display: number.uint32Value)
    }

    /// Begins reading: on the pace, and at once when the system does announce a change.
    func start() {
        guard observations.isEmpty else { return }
        let read: @MainActor @Sendable () -> Void = { [weak self] in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        observations = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification]
            .map { NotificationObservation(center: workspace, name: $0, changed: read) }
        observations.append(NotificationObservation(center: .default, name: NSApplication.didChangeScreenParametersNotification,
                                                    changed: read))
        // Nothing is read while the display sleeps.
        observations.append(NotificationObservation(center: workspace, name: NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.asleep = true; self?.schedule()
        })
        observations.append(NotificationObservation(center: workspace, name: NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.asleep = false; self?.refresh(); self?.schedule()
        })
        refresh(); schedule()
    }

    func stop() {
        observations = []; timer?.invalidate(); timer = nil
    }

    /// One step of the pace: a reading while the Mac is in use, and now and then while it is left alone.
    func tick() {
        if idle() > Self.rest, let lastRead, uptime() - lastRead < Self.leftAlonePace { return }
        refresh()
    }

    func refresh() {
        var next: Set<CGDirectDisplayID> = [], fullScreen: Set<CGDirectDisplayID> = []
        lastRead = uptime()
        if leave == .always || (leave == .withMenuBar && !barStays()) {
            // The kind of Space settles full screen; the windows are listed only to learn of it early, while an
            // application is still moving into it.
            let kinds = spaces(), all = displays(), point = pointer()
            let list = all.keys.allSatisfy(kinds.contains) ? [] : windows()
            for (display, frame) in all where kinds.contains(display) || FullScreenScene.owner(of: frame, windows: list) != nil {
                fullScreen.insert(display)
                guard leave == .withMenuBar else { next.insert(display); continue }
                // AC-42.02: the pointer at the top edge calls the menu bar down, and the bar stays while the
                // pointer is in its strip.
                let depth = point.y - frame.minY, within = point.x >= frame.minX && point.x < frame.maxX && depth >= 0
                if within, depth <= Self.edge { peeking.insert(display) } else if !within || depth > Self.strip { peeking.remove(display) }
                if !peeking.contains(display) { next.insert(display) }
            }
        }
        peeking.formIntersection(fullScreen)
        guard next != quiet else { return }
        quiet = next
        changed?()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Runs the pace while there is something to read for.
    private func schedule() {
        guard !observations.isEmpty, leave != .never, !asleep else { timer?.invalidate(); timer = nil; return }
        if let timer, timer.isValid { return }
        let next = Timer(timeInterval: Self.pace, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        next.tolerance = Self.pace / 5
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    nonisolated static func onScreenWindows() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return ScreenWindow(pid: pid, layer: layer, frame: frame)
        }
    }

    /// The displays whose Space in front is a full-screen one. The system has no public way to ask, so its own
    /// listing of Spaces is looked up when Lunlet runs; where that listing is missing or reads differently, no
    /// display is named and a window that covers the display is the only sign left.
    nonisolated static func fullScreenSpaces() -> Set<CGDirectDisplayID> {
        typealias Connection = @convention(c) () -> Int32
        typealias Listing = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let anywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(anywhere, "CGSMainConnectionID"), let listing = dlsym(anywhere, "CGSCopyManagedDisplaySpaces"),
              let entries = unsafeBitCast(listing, to: Listing.self)(unsafeBitCast(connection, to: Connection.self)())?
                .takeRetainedValue() as? [[String: Any]] else { return [] }
        let displays = activeDisplays().keys
        var found: Set<CGDirectDisplayID> = []
        for entry in entries {
            guard let current = entry["Current Space"] as? [String: Any], current["type"] as? Int == fullScreenSpace,
                  let identifier = entry["Display Identifier"] as? String else { continue }
            // Displays that share their Spaces are listed once, under the main display.
            if identifier == "Main" { found.formUnion(displays); continue }
            for display in displays {
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { continue }
                if CFUUIDCreateString(nil, uuid) as String == identifier { found.insert(display) }
            }
        }
        return found
    }
    private nonisolated static let fullScreenSpace = 4

    /// The pointer in the window server's top-left coordinates.
    nonisolated static func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: -1, y: -1)
    }

    /// Seconds since the keyboard, pointer or trackpad was last touched; no permission is needed to ask.
    nonisolated static func sinceLastInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The system setting that keeps the menu bar in full screen.
    nonisolated static func menuBarStaysInFullScreen() -> Bool {
        UserDefaults.standard.bool(forKey: "AppleMenuBarVisibleInFullscreen")
    }

    nonisolated static func activeDisplays() -> [CGDirectDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return [:] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: identifiers.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
}
