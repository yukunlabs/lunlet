// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-10, AC-10.04; US-11, AC-11.02; US-12, AC-12.04.
import Foundation
@testable import LunletFeishu

final class SyntheticFeishuPath: FeishuPathObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let interruptOnStart: Bool
    init(interruptOnStart: Bool = false) { self.interruptOnStart = interruptOnStart }
    private var callback: (@Sendable () -> Void)?
    func start(onUnavailable: @escaping @Sendable () -> Void) {
        lock.withLock { callback = onUnavailable }
        if interruptOnStart { onUnavailable() }
    }
    func cancel() { lock.withLock { callback = nil } }
    func interrupt() { let current = lock.withLock { callback }; current?() }
}
