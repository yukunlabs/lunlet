// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-01, AC-01.05.
import Foundation
import LunletCore
import LunletFeishu

/// The owner identity a verified Feishu send receipt established, kept beside the enrollment so the
/// first locked card after a relaunch can already carry a reply box.
/// The tenant and owner IDs are identifiers, not credentials, so they live in Lunlet's preferences
/// rather than the Keychain. Only a verified receipt writes it, callbacks never do, and it is used only
/// for the same application and owner; removing the enrollment forgets it.
struct FeishuOwnerMemory: Sendable {
    private let key: String
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, key: String = "feishuVerifiedOwner") {
        self.defaults = defaults
        self.key = key
    }

    /// The remembered owner of this enrollment, or nil when none was verified for it.
    func owner(for enrollment: FeishuEnrollment) -> FeishuOwner? {
        guard let saved = defaults.dictionary(forKey: key) as? [String: String],
              saved["applicationID"] == enrollment.applicationID, saved["userID"] == enrollment.scannedOwnerID,
              let tenant = saved["tenantID"] else { return nil }
        let owner = FeishuOwner(applicationID: enrollment.applicationID, tenantID: tenant, userID: enrollment.scannedOwnerID)
        return owner.isComplete ? owner : nil
    }

    func remember(_ owner: FeishuOwner) {
        guard owner.isComplete else { return }
        defaults.set(["applicationID": owner.applicationID, "tenantID": owner.tenantID, "userID": owner.userID], forKey: key)
    }

    func forget() { defaults.removeObject(forKey: key) }
}
