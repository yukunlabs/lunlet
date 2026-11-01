// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.02, AC-06.05; US-33, AC-33.05.
import Foundation
import Testing
import LunletCore

struct NoticeTextTests {
    @Test func excerptsCollapseWhitespaceAndCutAtAWordBoundary() {
        #expect(NoticeText.excerpt("  Fix\n\tthe   build  ", limit: 40) == "Fix the build")
        #expect(NoticeText.excerpt("Fix the flaky parser test, then update the notes", limit: 30) == "Fix the flaky parser test…")
        #expect(NoticeText.excerpt(" \n\u{200B} ", limit: 40) == nil)
        // Unspaced scripts are cut at the limit rather than at a distant boundary.
        let unspaced = String((0..<80).map { Character(UnicodeScalar(0x4E00 + $0)!) })
        let cut = NoticeText.excerpt("Plan " + unspaced, limit: 40)
        #expect(cut?.count == 40 && cut?.hasSuffix("…") == true)
    }

    @Test func fittingKeepsTextThatFitsAndOtherwiseEndsWithTheNotice() throws {
        let text = "First paragraph with words.\n\nSecond paragraph with more words that will not fit."
        #expect(NoticeText.fitting(text) { _ in true } == text)
        let fitted = try #require(NoticeText.fitting(text) { $0.count <= 60 })
        #expect(fitted.count <= 60 && fitted.hasSuffix(NoticeText.truncationNotice))
        #expect(fitted.hasPrefix("First paragraph") && !fitted.contains("wor\n"))
        // Already shortened text always says so, and nothing fits when even the notice does not.
        #expect(NoticeText.fitting("Short", alreadyShortened: true) { _ in true } == "Short\n\n" + NoticeText.truncationNotice)
        #expect(NoticeText.fitting(text) { $0.count < 5 } == nil)
    }

    @Test func fittingClosesAnOpenCodeFence() throws {
        let text = "Changed:\n\n```swift\n" + (0..<200).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n```\nDone."
        let fitted = try #require(NoticeText.fitting(text) { $0.utf8.count <= 600 })
        let fences = fitted.split(separator: "\n", omittingEmptySubsequences: false).filter(NoticeText.isFence)
        #expect(fences.count % 2 == 0 && fitted.hasSuffix("```\n\n" + NoticeText.truncationNotice))
        #expect(fitted.utf8.count <= 600)
    }

    @Test func prefixNeverSplitsACharacter() {
        let text = "ab" + String(repeating: "é", count: 10) + "🙂"
        let cut = NoticeText.prefix(text, utf8Limit: 7)
        #expect(cut == "abéé" && cut.utf8.count <= 7)
        #expect(NoticeText.prefix(text, utf8Limit: 1_000) == text)
    }

    @Test func cleaningKeepsLinesAndEmojiButDropsInvisibleControls() {
        let raw = "Title\r\n\r\n\r\n- item\u{0000}\t  \n\u{202E}reversed\u{2066}\n👩‍💻 done\n\n\n"
        #expect(NoticeText.cleanMarkdown(raw) == "Title\n\n- item\nreversed\n👩‍💻 done")
    }

    @Test func redactionHidesSecretsAndShortensHomeFoldersOnly() {
        let (plain, plainHidden) = NoticeText.redact("Edited /Users/synthetic/project/App.swift and /home/synthetic/x.")
        #expect(plain == "Edited ~/project/App.swift and ~/x." && !plainHidden)
        let samples = ["ghp_" + String(repeating: "a", count: 30), "xoxb-" + String(repeating: "1", count: 20),
                       "AKIA" + String(repeating: "B", count: 16), "123456789:" + String(repeating: "c", count: 35),
                       "https://user:synthetic@example.invalid", "password: synthetic-value"]
        for sample in samples {
            let (value, hidden) = NoticeText.redact("Use " + sample + " now")
            #expect(hidden && value.contains("[hidden]") && !value.contains("synthetic-value"))
        }
        #expect(NoticeText.redact("<think>private</think>Visible").text == "Visible")
        #expect(NoticeText.redact("Visible <thinking>unclosed private").text == "Visible ")
    }
}
