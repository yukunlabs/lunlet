// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-26, AC-26.01, AC-26.02.
import Foundation
import Testing

/// Settings for one test. A settings domain named by an absolute path keeps its file at that path, so these live in
/// a temporary directory and never in the user's Library, where a domain leaves an empty file behind even after it
/// is removed. The directory goes when the test process ends.
enum ScratchSettings {
    private static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lunlet-test-settings-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ScratchSettings.directory) }
        return url
    }()

    /// A fresh, empty domain and its name; `label` only tells the files of different suites apart.
    static func make(_ label: String) throws -> (defaults: UserDefaults, name: String) {
        let name = directory.appendingPathComponent("\(label)-\(UUID().uuidString)").path
        return (try #require(UserDefaults(suiteName: name)), name)
    }
}
