// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
import Foundation
import OSLog
import Testing
import LunletCore

struct DiagnosticLogTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_DIAGNOSTICS"] == "1"))
    func nativeLogRetainsTypedOutcomesAndOneOpaqueOperationIdentifier() async throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-1))
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.connection, component: .feishu, outcome: .started, operation: operation)
        DiagnosticLog.record(.connection, component: .feishu, outcome: .failed, operation: operation,
                             reason: .provider, code: 514)
        let predicate = NSPredicate(format: "subsystem == %@ AND composedMessage CONTAINS %@",
                                    "com.lunlet", operation.id.uuidString)
        var messages: [String] = []
        for _ in 0..<20 {
            messages = try store.getEntries(at: position, matching: predicate).compactMap {
                ($0 as? OSLogEntryLog)?.composedMessage
            }
            if messages.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(messages.count == 2)
        #expect(messages.contains { $0.contains("event=connection") && $0.contains("outcome=started") })
        #expect(messages.contains { $0.contains("outcome=failed") && $0.contains("reason=provider") && $0.contains("code=514") })
    }
}
