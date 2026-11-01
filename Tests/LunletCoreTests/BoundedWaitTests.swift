// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.04; US-14, AC-14.01.
import Foundation
import Testing
@testable import LunletCore

struct BoundedWaitTests {
    @Test func aFinishedTaskSettlesAndAStalledOneIsLeftBehindAfterTheLimit() async {
        let quick = Task { 1 }
        #expect(await BoundedWait.settle(quick, limit: .seconds(10)))
        // A cleanup that never ends, like a receive on a socket that will not answer: the wait returns on time and
        // the task is still running afterwards, not cancelled.
        let stalled = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) } }
        #expect(await BoundedWait.settle(stalled, limit: .milliseconds(100)) == false)
        #expect(!stalled.isCancelled)
        stalled.cancel()
        #expect(await BoundedWait.settle(stalled, limit: .seconds(10)))
    }
}
