// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-01, AC-01.05.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop
@testable import LunletFeishu

struct FeishuOwnerMemoryTests {
    private func memory() throws -> (FeishuOwnerMemory, UserDefaults, String) {
        let suite = "com.lunlet.tests.owner-memory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (FeishuOwnerMemory(defaults: defaults), defaults, suite)
    }

    private let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                              secret: "synthetic-secret", isLark: false)

    /// Verifies AC-05.09: a verified owner is restored only for the same application and owner, and forgetting it
    /// with the enrollment leaves nothing to restore.
    @Test func aVerifiedOwnerIsRestoredOnlyForTheSameEnrollment() throws {
        let (memory, defaults, suite) = try memory()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(memory.owner(for: enrollment) == nil)
        memory.remember(FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_synthetic"))
        #expect(memory.owner(for: enrollment)
                == FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_synthetic"))
        let otherApp = FeishuEnrollment(applicationID: "cli_other", scannedOwnerID: "ou_synthetic",
                                        secret: "synthetic-secret", isLark: false)
        let otherOwner = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_other",
                                          secret: "synthetic-secret", isLark: false)
        #expect(memory.owner(for: otherApp) == nil && memory.owner(for: otherOwner) == nil)
        // An incomplete identity is never kept.
        memory.remember(FeishuOwner(applicationID: "cli_synthetic", tenantID: "", userID: "ou_synthetic"))
        #expect(memory.owner(for: enrollment)?.tenantID == "tenant_synthetic")
        memory.forget()
        #expect(memory.owner(for: enrollment) == nil)
    }
}
