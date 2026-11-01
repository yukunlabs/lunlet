// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.02, AC-13.06.
// Refs: US-03, AC-03.06; US-12, AC-12.04; US-05, AC-05.06.
import AppKit
import IOKit

/// Unknown OS state suppresses cues. Notifications only prompt a fresh read;
/// neither their name nor their payload establishes that a screen is unlocked.
@MainActor enum SystemDisplayState {
    // Lock state is independent of display sleep; unknown never enables delivery.
    static var isLocked: Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session[kCGSessionUserIDKey as String] as? Int == Int(geteuid()) else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFEqual(value, kCFBooleanTrue)
    }

    static var isAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session[kCGSessionUserIDKey as String] as? Int == Int(geteuid()) else { return false }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID(), CFEqual(value, kCFBooleanFalse) else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }
}

final class NotificationObservation {
    let center: NotificationCenter
    let token: NSObjectProtocol
    convenience init(center: NotificationCenter, name: Notification.Name, changed: @escaping @MainActor @Sendable () -> Void) {
        self.init(center: center, name: name, value: { _ in () }, receive: { _ in changed() })
    }
    init<Value: Sendable>(center: NotificationCenter, name: Notification.Name,
                         value: @escaping @Sendable (Notification) -> Value,
                         receive: @escaping @MainActor @Sendable (Value) -> Void) {
        self.center = center
        // Delivery on the main queue already runs on the main actor; no extra task hop.
        token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            let payload = value(notification)
            MainActor.assumeIsolated { receive(payload) }
        }
    }
    deinit { center.removeObserver(token) }
}

@MainActor final class DisplayStateMonitor {
    private var observations: [NotificationObservation] = []
    private var settling: Task<Void, Never>?
    private let changed: @MainActor @Sendable () -> Void

    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
        let notify: @MainActor @Sendable () -> Void = { [weak self] in self?.recheck() }
        let workspace = NSWorkspace.shared.notificationCenter
        var entries = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                       NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
            .map { NotificationObservation(center: workspace, name: $0, changed: notify) }
        entries.append(NotificationObservation(center: .default, name: NSApplication.didChangeScreenParametersNotification, changed: notify))
        let distributed = DistributedNotificationCenter.default()
        entries += ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map {
            NotificationObservation(center: distributed, name: .init($0), changed: notify)
        }
        observations = entries
    }

    /// OS notifications may precede settled console/display properties. Re-read
    /// briefly after a signal; there is no idle timer and another signal replaces
    /// this finite sequence. Consumers still verify the actual state on each read.
    func recheck() {
        settling?.cancel()
        changed()
        settling = Task { [weak self] in
            for delay in [100, 200, 700, 1_000, 2_000, 4_000] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.changed()
            }
        }
    }

    deinit { settling?.cancel() }
}
