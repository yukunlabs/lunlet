// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-20, AC-20.03; US-33, AC-33.05; US-36, AC-36.01, AC-36.03.
import Foundation
import LunletCore

/// One Telegram message in HTML parse mode, in the order of the Feishu card: the agent and the event with the
/// project, the session title, the quoted request, the reply, any notes and the reply line. Telegram shows the
/// time itself. Supplied text is always escaped; the reply's common Markdown becomes a few well-nested tags,
/// so it can never form other tags.
enum TelegramNoticeMessage {
    /// Telegram's message limit, measured conservatively on the HTML before entity parsing.
    static let limit = 4_096

    /// `reply` adds the reply line: the invitation while open, otherwise the reply's state; nil shows no reply affordance.
    static func html(_ notice: SessionNotice, reply: NoticeReplyState?) -> String {
        let result = notice.result()
        func compose(_ text: String?) -> String {
            var parts = ["<b>" + escape(notice.agentHeadline) + "</b> · " + escape(notice.project)
                         + (notice.titleIsPlaceholder ? "" : "\n<i>" + escape(notice.title) + "</i>")]
            if let request = notice.request { parts.append("<blockquote>" + escape(request) + "</blockquote>") }
            let body = text.map(markdown) ?? escape(result.fallback)
            // A finished turn's reply follows its request unlabeled; other events name what the session needs.
            // A long reply folds into an expandable quote so the chat stays readable; code blocks cannot fold.
            let folded = body.utf16.count > foldLimit && !body.contains("<pre>")
                ? "<blockquote expandable>" + body + "</blockquote>" : body
            parts.append(notice.resultLabel == "Result" ? folded : "<b>" + escape(notice.resultLabel) + "</b>\n" + folded)
            let notes = notice.notes + [result.note].compactMap { $0 }
            if !notes.isEmpty { parts.append("<i>" + escape(notes.joined(separator: "\n")) + "</i>") }
            if let reply, let line = replyLine(reply, agent: notice.agent) { parts.append(line) }
            return parts.joined(separator: "\n\n")
        }
        guard let text = result.text else { return compose(nil) }
        let fitted = NoticeText.fitting(text, alreadyShortened: result.shortened) { compose($0).utf16.count <= limit }
        return compose(fitted ?? NoticeText.truncationNotice)
    }

    /// Replies longer than this fold; Telegram shows the first lines and an expand control.
    static let foldLimit = 600

    /// The reply's state under the notice; an open notice shows its button instead of a line.
    static func replyLine(_ state: NoticeReplyState, agent: String) -> String? {
        guard let status = NoticeReplyText.status(state, agent: agent) else { return nil }
        return "<b>" + escape(status.label) + "</b> · " + escape(status.detail)
    }

    /// The inline keyboard of an open notice; absent in every other state, which removes it from an edited message.
    static func replyMarkup(_ state: NoticeReplyState?) -> [String: Any]? {
        guard state == .open else { return nil }
        return ["inline_keyboard": [[["text": NoticeReplyText.replyButton, "callback_data": "reply"]]]]
    }

    /// Fenced code becomes `pre`, inline code `code`, headings and `**bold**` `b`, http(s) links `a`, and list
    /// markers bullets. Everything else stays escaped text. Tags never overlap, so Telegram always parses them.
    static func markdown(_ text: String) -> String {
        var fenced = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            if NoticeText.isFence(raw) {
                defer { fenced.toggle() }
                if fenced { return "</code></pre>" }
                let language = raw.drop(while: { $0 == " " || $0 == "`" || $0 == "~" }).prefix(while: { !$0.isWhitespace })
                let safe = !language.isEmpty && language.count <= 32
                    && language.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-_#.".contains($0)) }
                return safe ? "<pre><code class=\"language-" + language + "\">" : "<pre><code>"
            }
            if fenced { return escape(String(raw)) }
            var line = String(raw)
            let indent = String(line.prefix(while: { $0 == " " }))
            line.removeFirst(indent.count)
            if let heading = line.range(of: #"^#{1,6} +"#, options: .regularExpression) {
                let title = String(line[heading.upperBound...]).replacingOccurrences(of: "**", with: "")
                return title.isEmpty ? "" : "<b>" + inline(title) + "</b>"
            }
            if let bullet = line.range(of: #"^[-*+] +"#, options: .regularExpression) {
                return indent + "• " + inline(String(line[bullet.upperBound...]))
            }
            return indent + inline(line)
        }.joined(separator: "\n") + (fenced ? "</code></pre>" : "")
        // Code starts and ends with its own text, not with the fence lines' breaks.
        return lines.replacingOccurrences(of: #"(<pre><code[^>]*>)\n"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\n</code></pre>", with: "</code></pre>")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Odd spans between backticks are code; an unmatched last backtick stays literal.
    private static func inline(_ line: String) -> String {
        let spans = line.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        let closed = spans.count % 2 == 1
        return spans.enumerated().map { index, span -> String in
            let code = index % 2 == 1 && (closed || index < spans.count - 1)
            if code { return "<code>" + escape(span) + "</code>" }
            var value = escape(span)
            for (pattern, template) in rules {
                value = pattern.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
            }
            return (index % 2 == 1 ? "`" : "") + value
        }.joined()
    }

    /// Link text and bold text exclude tag and marker characters, so no generated tag can straddle another.
    private static let rules: [(NSRegularExpression, String)] = [
        (#"\[([^\]\[*<>]+)\]\((https?://[^)\s"<>]+)\)"#, "<a href=\"$2\">$1</a>"),
        (#"\*\*([^*<>]+?)\*\*"#, "<b>$1</b>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
