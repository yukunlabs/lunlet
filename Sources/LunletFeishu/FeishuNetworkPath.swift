// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-10, AC-10.04; US-11, AC-11.02; US-12, AC-12.04.
import Foundation
import Network

protocol FeishuPathObserving: Sendable {
    func start(onUnavailable: @escaping @Sendable () -> Void)
    func cancel()
}

final class SystemFeishuPath: FeishuPathObserving, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lunlet.feishu-path")
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start(onUnavailable: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !started, !cancelled else { return }
            started = true
            monitor.pathUpdateHandler = { path in
                // On-demand connections may first require activation; only confirmed loss closes access.
                if path.status == .unsatisfied { onUnavailable() }
            }
            monitor.start(queue: queue)
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
    }

    deinit { monitor.cancel() }
}
