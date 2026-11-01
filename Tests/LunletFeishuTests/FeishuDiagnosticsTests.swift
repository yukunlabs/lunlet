// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
import Foundation
import OSLog
import Testing
import LunletCore
@testable import LunletFeishu

/// Reads only this synthetic test process's Lunlet events.
struct NativeDiagnosticCapture {
    private let store: OSLogStore
    private let position: OSLogPosition
    init() throws {
        store = try OSLogStore(scope: .currentProcessIdentifier)
        position = store.position(date: Date())
    }
    func read(until needle: String) async throws -> [String] {
        let predicate = NSPredicate(format: "subsystem == %@", "com.lunlet")
        var messages: [String] = []
        for _ in 0..<20 {
            messages = try store.getEntries(at: position, matching: predicate).compactMap {
                ($0 as? OSLogEntryLog)?.composedMessage
            }
            if messages.contains(where: { $0.contains(needle) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return messages
    }
}

struct FeishuDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_DIAGNOSTICS"] == "1"))
    func uncertainDeliveryIsNotReportedAsCancelled() async throws {
        let capture = try NativeDiagnosticCapture()
        let operation = DiagnosticOperation()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            FeishuDiagnostics.failure(.cardDelivery, operation: operation, error: FeishuBotFailure.deliveryUncertain)
        }
        await cancelled.value
        let entries = try await capture.read(until: operation.id.uuidString).filter { $0.contains(operation.id.uuidString) }
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.contains("outcome=uncertain") })
    }
}
