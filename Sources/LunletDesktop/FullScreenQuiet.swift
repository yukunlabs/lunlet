// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-42, AC-42.01, AC-42.02, AC-42.03, AC-42.04.
import AppKit
import Darwin
import IOKit.pwr_mgt

/// When the notch entry steps aside for another application's full-screen window (AC-42.03).
enum FullScreenPolicy: String, Codable, CaseIterable, Sendable {
    case video, always, never
    var title: String {
        switch self { case .video: "During video"; case .always: "Always"; case .never: "Never" }
    }
}

/// A window as the window server lists it: its owner, its layer and its frame in the server's top-left coordinates.
struct ScreenWindow: Equatable {
    let pid: pid_t
    let layer: Int
    let frame: CGRect
}

/// A process that keeps the display from sleeping.
struct AwakeProcess: Equatable {
    let pid: pid_t
    let path: String
}

/// What the windows on a display and the processes keeping it awake say about full screen. Only public facts are
/// read: frames and owners of windows, never their titles or contents, and which processes hold a display assertion.
enum FullScreenScene {
    /// The application whose window fills `display`, or nil. In full screen a window covers the whole display, the
    /// menu bar's strip included, which no ordinary window can; `windows` are front to back.
    static func owner(of display: CGRect, windows: [ScreenWindow]) -> pid_t? {
        var front: pid_t?
        for window in windows where window.layer == 0 && window.frame.intersects(display) {
            // Another application's window in front means the filling window is not what is being looked at; the
            // application's own sheet or controls in front of it change nothing.
            if let front, front != window.pid { return nil }
            if window.frame.insetBy(dx: -1, dy: -1).contains(display) { return window.pid }
            front = window.pid
        }
        return nil
    }

    /// Whether the full-screen application keeps the display awake, as a video, a presentation or a call does:
    /// itself, a helper inside its bundle, or WebKit's own processes when it is Safari.
    static func showsVideo(owner: pid_t, bundlePath: String?, bundleID: String?, awake: [AwakeProcess]) -> Bool {
        awake.contains { process in
            if process.pid == owner { return true }
            if let bundlePath, process.path.hasPrefix(bundlePath + "/") { return true }
            return bundleID?.hasPrefix("com.apple.Safari") == true && process.path.contains("/WebKit.framework/")
        }
    }

    static func isQuiet(policy: FullScreenPolicy, fullScreen: Bool, video: Bool) -> Bool {
        switch policy {
        case .never: false
        case .always: fullScreen
        case .video: fullScreen && video
        }
    }
}

/// Tells every part of Lunlet whether a display is given over to another application's full-screen window, from one
/// reading of the system. It reads on a change of Space, application or displays, a few more times as that change
/// settles, and once a second only while some display is in full screen, where video can start without any
/// notification (AC-42.04).
@MainActor final class FullScreenQuiet {
    static let shared = FullScreenQuiet()
    static let didChange = Notification.Name("com.lunlet.fullScreenQuietChanged")

    var policy = FullScreenPolicy.video {
        didSet { if policy != oldValue { refresh() } }
    }
    var changed: (() -> Void)?
    /// A display is in full screen, so the answer may change without a notification.
    private(set) var watching = false
    /// How often to read while watching, and when to read again after a change: the system announces a new Space
    /// or application before the window has grown to fill the display.
    static let interval: TimeInterval = 1
    static let settling: [TimeInterval] = [0.2, 0.5, 0.9, 1.5]
    /// Runs work after a delay; tests run it at once.
    var later: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    private var quiet: Set<CGDirectDisplayID> = []
    /// The application seen playing video in full screen on each display. While it stays the full-screen one there,
    /// a pause or a moment of buffering does not bring the entry back over the picture (AC-42.01).
    private var playing: [CGDirectDisplayID: pid_t] = [:]
    private let windows: () -> [ScreenWindow]
    private let awake: () -> [AwakeProcess]
    private let application: (pid_t) -> (path: String?, id: String?)
    private let displays: () -> [CGDirectDisplayID: CGRect]
    private var observations: [NotificationObservation] = []
    private var timer: Task<Void, Never>?

    init(windows: @escaping () -> [ScreenWindow] = FullScreenQuiet.onScreenWindows,
         awake: @escaping () -> [AwakeProcess] = FullScreenQuiet.displayAssertions,
         application: @escaping (pid_t) -> (path: String?, id: String?) = FullScreenQuiet.bundle,
         displays: @escaping () -> [CGDirectDisplayID: CGRect] = FullScreenQuiet.activeDisplays) {
        self.windows = windows; self.awake = awake; self.application = application; self.displays = displays
    }

    func isQuiet(display: CGDirectDisplayID) -> Bool { quiet.contains(display) }
    func isQuiet(_ screen: NSScreen?) -> Bool {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return isQuiet(display: number.uint32Value)
    }

    /// Begins reading on the system's own signals; nothing runs between them unless a display is in full screen.
    func start() {
        guard observations.isEmpty else { return }
        let read: @MainActor @Sendable () -> Void = { [weak self] in self?.systemChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        observations = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification]
            .map { NotificationObservation(center: workspace, name: $0, changed: read) }
        observations.append(NotificationObservation(center: .default, name: NSApplication.didChangeScreenParametersNotification,
                                                    changed: read))
        refresh()
    }

    func stop() {
        observations = []; timer?.cancel(); timer = nil
    }

    /// The system announced a change that can begin or end full screen: read now, and again as it settles.
    func systemChanged() {
        refresh()
        for delay in Self.settling { later(delay) { [weak self] in self?.refresh() } }
    }

    func refresh() {
        var next: Set<CGDirectDisplayID> = [], fullScreen = false, stillPlaying: [CGDirectDisplayID: pid_t] = [:]
        if policy != .never {
            let list = windows()
            var holders: [AwakeProcess]?
            for (display, frame) in displays() {
                guard let owner = FullScreenScene.owner(of: frame, windows: list) else { continue }
                fullScreen = true
                var video = false
                if policy == .video {
                    video = playing[display] == owner
                    if !video {
                        let awakeNow = holders ?? awake()
                        holders = awakeNow
                        let bundle = application(owner)
                        video = FullScreenScene.showsVideo(owner: owner, bundlePath: bundle.path, bundleID: bundle.id, awake: awakeNow)
                    }
                    if video { stillPlaying[display] = owner }
                }
                if FullScreenScene.isQuiet(policy: policy, fullScreen: true, video: video) { next.insert(display) }
            }
        }
        playing = stillPlaying
        watching = fullScreen
        if next != quiet {
            quiet = next
            changed?()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        if watching, !observations.isEmpty {
            if timer == nil {
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(Self.interval)) } catch { return }
                        guard let self, self.watching else { return }
                        self.refresh()
                    }
                }
            }
        } else {
            timer?.cancel(); timer = nil
        }
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

    /// The processes holding an assertion that keeps the display awake.
    nonisolated static func displayAssertions() -> [AwakeProcess] {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let display: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        return byProcess.compactMap { pid, assertions in
            guard assertions.contains(where: {
                display.contains($0[kIOPMAssertionTypeKey] as? String ?? "") && ($0[kIOPMAssertionLevelKey] as? Int ?? 0) != 0
            }) else { return nil }
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid.int32Value, &buffer, UInt32(buffer.count))
            return AwakeProcess(pid: pid.int32Value, path: length > 0 ? String(cString: buffer) : "")
        }
    }

    nonisolated static func bundle(_ pid: pid_t) -> (path: String?, id: String?) {
        let application = NSRunningApplication(processIdentifier: pid)
        return (application?.bundleURL?.path, application?.bundleIdentifier)
    }

    nonisolated static func activeDisplays() -> [CGDirectDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return [:] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: identifiers.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
}
