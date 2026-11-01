// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-20, AC-20.03; US-33, AC-33.05; US-36, AC-36.01, AC-36.03.
// Synthetic notices only; nothing is sent.
import Foundation
import Testing
import LunletCore
@testable import LunletMessaging

struct NoticeMessageTests {
    private func notice(_ reply: String?, outcome: TaskCue.Outcome = .succeeded, preview: String? = "Fix the parser",
                        phase: SessionPhase = .idle(completedTurnID: "turn"), title: String? = nil) -> SessionNotice {
        .prepare(SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: phase),
                                 project: "lunlet", title: title, publicConclusion: reply, outcome: outcome, localPreview: preview))
    }
    private func texts(_ blocks: [[String: Any]]) -> [String] {
        blocks.compactMap { block in
            (block["text"] as? [String: Any])?["text"] as? String
                ?? ((block["elements"] as? [[String: Any]])?.first?["text"] as? String)
        }
    }

    // The Slack notice follows the card: agent and event with the project, the session title, the quoted request,
    // the reply, then the reply line; no footer, because Slack shows the time.
    @Test func slackBlocksFollowTheCardOrder() throws {
        let value = notice("Done.\n\nTests pass.", title: "Parser")
        let body = SlackNoticeMessage.body(value, channel: "DTEST", reply: nil)
        let blocks = try #require(body["blocks"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["header", "context", "section", "section"])
        #expect(texts(blocks) == ["Codex succeeded · lunlet", "Parser", "&gt; Fix the parser", "Done.\n\nTests pass."])
        #expect(body["text"] as? String == "Codex succeeded · lunlet — Fix the parser")
        #expect(!body.description.contains("Approvals stay") && !body.description.contains("Replies from your phone"))
        // A placeholder title is not repeated; a missing result and a wait say so, labeled.
        let missing = SlackNoticeMessage.body(notice(nil, outcome: .unknown, preview: nil), channel: "DTEST", reply: nil)
        #expect(texts(try #require(missing["blocks"] as? [[String: Any]])) == ["Codex finished · lunlet", "Result not captured — open it on your Mac."])
        let approval = SlackNoticeMessage.body(notice(nil, phase: .approval), channel: "DTEST", reply: nil)
        let approvalTexts = texts(try #require(approval["blocks"] as? [[String: Any]]))
        #expect(approvalTexts[0] == "Codex needs approval · lunlet" && approvalTexts.last?.hasPrefix("*Needs you*\n") == true)
    }

    // The reply line invites one thread reply while open and then states the reply's progress or why it closed.
    @Test func slackReplyLineShowsTheInvitationThenTheState() throws {
        let value = notice("Done.")
        func last(_ reply: NoticeReplyState?) throws -> String {
            let blocks = try #require(SlackNoticeMessage.body(value, channel: "DTEST", reply: reply)["blocks"] as? [[String: Any]])
            return try #require(texts(blocks).last)
        }
        #expect(try last(.open) == "_Reply in this thread within 10 min while your Mac stays locked to continue this session._")
        #expect(try last(.received("Go")) == "*Received* · sending to Codex…")
        #expect(try last(.finished(.delivered, "Go")) == "*Delivered* · Codex is continuing on your Mac")
        #expect(try last(.finished(.refused(.sessionRunning), "Go")) == "*Not sent* · The session is already working on another turn.")
        #expect(try last(.closed(.replyWindowClosed)) == "*Replies closed* · Replies stopped when your Mac was unlocked. Continue on your Mac.")
        #expect(try last(nil) == "Done.")
    }

    @Test func slackMrkdwnTranslatesCommonMarkdownOutsideCode() {
        let markdown = "# Summary\n- **Bold** and *italic* and ~~gone~~\n  * nested\n[docs](https://example.invalid/a?b=1&c=2) or https://example.invalid/x.\n---\n```swift\nlet a = b < c && **d**\n```\nUse `**raw**` <@U123> <!channel>"
        let expected = "*Summary*\n• *Bold* and _italic_ and ~gone~\n  • nested\n<https://example.invalid/a?b=1&amp;c=2|docs> or <https://example.invalid/x>.\n──────────\n```\nlet a = b &lt; c &amp;&amp; **d**\n```\nUse `**raw**` &lt;@U123&gt; &lt;!channel&gt;"
        #expect(SlackNoticeMessage.mrkdwn(markdown) == expected)
    }

    @Test func slackSplitsLongResultsIntoSectionsAndReopensCode() {
        let code = "```\n" + (0..<400).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n```"
        let chunks = SlackNoticeMessage.chunks(code, limit: 3_000)
        #expect(chunks.count > 1 && chunks.allSatisfy { $0.utf16.count <= 3_000 })
        #expect(chunks.allSatisfy { $0.hasPrefix("```") && $0.hasSuffix("```") })
        // One unbroken word is split rather than exceeding the section limit.
        #expect(SlackNoticeMessage.chunks(String(repeating: "x", count: 7_000)).allSatisfy { $0.utf16.count <= 3_000 })
    }

    @Test func slackRespectsTheBlockLimitAndSaysTheRestIsOnTheMac() throws {
        let paragraphs = (0..<1_200).map { "Paragraph \($0) " + String(repeating: "words ", count: 20) }.joined(separator: "\n\n")
        let value = notice(paragraphs)
        let blocks = try #require(SlackNoticeMessage.body(value, channel: "DTEST", reply: .open)["blocks"] as? [[String: Any]])
        #expect(blocks.count <= SlackNoticeMessage.blockLimit)
        let sections = blocks.filter { $0["type"] as? String == "section" }.dropFirst()
        #expect(sections.count > 10 && texts(Array(sections)).allSatisfy { $0.utf16.count <= SlackNoticeMessage.sectionLimit })
        #expect(texts(Array(sections)).last?.hasSuffix(NoticeText.truncationNotice) == true)
        #expect(blocks.last?["type"] as? String == "context")
    }

    // The Telegram notice follows the card too, with the reply line replacing the footer.
    @Test func telegramEscapesSuppliedTextAndKeepsTheOrder() throws {
        let value = notice("Use <b>tags</b> & **Markdown**.", preview: "Check <a href=\"x\">this</a>")
        #expect(TelegramNoticeMessage.html(value, reply: nil) == "<b>Codex succeeded</b> · lunlet\n\n"
            + "<blockquote>Check &lt;a href=\"x\"&gt;this&lt;/a&gt;</blockquote>\n\n"
            + "Use &lt;b&gt;tags&lt;/b&gt; &amp; <b>Markdown</b>.")
        // An open notice carries its reply button instead of a text line.
        let titled = TelegramNoticeMessage.html(notice("Done.", title: "Parser <1>"), reply: .open)
        #expect(titled == "<b>Codex succeeded</b> · lunlet\n<i>Parser &lt;1&gt;</i>\n\n<blockquote>Fix the parser</blockquote>\n\nDone.")
        let keyboard = try #require(TelegramNoticeMessage.replyMarkup(.open)?["inline_keyboard"] as? [[[String: String]]])
        #expect(keyboard == [[["text": "↩ Reply to continue", "callback_data": "reply"]]])
        #expect(TelegramNoticeMessage.replyMarkup(.received("Go")) == nil && TelegramNoticeMessage.replyMarkup(nil) == nil)
        #expect(TelegramNoticeMessage.html(notice("Done."), reply: .finished(.delivered, "Go")).hasSuffix("\n\n<b>Delivered</b> · Codex is continuing on your Mac"))
        #expect(TelegramNoticeMessage.html(notice("Done."), reply: .closed(.expired)).hasSuffix("<b>Replies closed</b> · This notice has expired. Continue on your Mac."))
        let approval = TelegramNoticeMessage.html(notice(nil, phase: .approval), reply: nil)
        #expect(approval.hasPrefix("<b>Codex needs approval</b> · lunlet") && approval.contains("<b>Needs you</b>\nCodex is waiting for an execution approval."))
    }

    @Test func telegramTranslatesCommonMarkdownIntoWellNestedTags() {
        let markdown = "## Done **now**\n- **Bold** and [docs](https://example.invalid/a?b=1&c=2)\n```swift\nlet a = b < c\n```\n"
            + "Use `x<y` and `unclosed\n**a *b** c* and [**x**](https://example.invalid) and [y](javascript:alert)"
        #expect(TelegramNoticeMessage.markdown(markdown) == "<b>Done now</b>\n• <b>Bold</b> and "
            + "<a href=\"https://example.invalid/a?b=1&amp;c=2\">docs</a>\n<pre><code class=\"language-swift\">let a = b &lt; c</code></pre>\n"
            + "Use <code>x&lt;y</code> and `unclosed\n**a *b** c* and [<b>x</b>](https://example.invalid) and [y](javascript:alert)")
        // An unclosed fence is closed, and a hostile language hint is dropped.
        #expect(TelegramNoticeMessage.markdown("```\"><b>\ncode") == "<pre><code>code</code></pre>")
    }

    @Test func telegramFitsOneMessageAndSaysTheRestIsOnTheMac() throws {
        let value = notice(String(repeating: "A long synthetic reply & more. ", count: 400))
        let html = TelegramNoticeMessage.html(value, reply: .open)
        #expect(html.utf16.count <= TelegramNoticeMessage.limit)
        // A long reply folds into an expandable quote; a short one or one with code stays plain.
        #expect(html.hasSuffix(NoticeText.truncationNotice + "</blockquote>") && html.contains("<blockquote expandable>"))
        #expect(!TelegramNoticeMessage.html(notice("```\n" + String(repeating: "x\n", count: 400) + "```"), reply: nil).contains("expandable"))
        #expect(html.components(separatedBy: "<b>").count == html.components(separatedBy: "</b>").count)
    }
}
