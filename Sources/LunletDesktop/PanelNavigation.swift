// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-31, AC-31.01, AC-31.03; US-39, AC-39.05, AC-39.07; US-19, AC-19.02, AC-19.03.
import Combine
import LunletCore

/// Which page the panel shows. It lives outside the panel's view, so an entry's menu or the application menu can
/// ask for a page before the panel's content exists, and the choice can be checked without a window.
@MainActor final class PanelNavigation: ObservableObject {
    /// Home is the single selected provider's page, or the Overview when several are selected.
    enum Page: Equatable { case home, provider(SessionProvider), settings }
    @Published var page: Page
    /// The Settings category a page asked for; nil opens the default category.
    @Published var settingsEntry: PreferenceCategory?

    init(page: Page = .home, settingsEntry: PreferenceCategory? = nil) {
        self.page = page; self.settingsEntry = settingsEntry
    }

    func openSettings(_ category: PreferenceCategory? = nil) {
        settingsEntry = category; page = .settings
    }
}
