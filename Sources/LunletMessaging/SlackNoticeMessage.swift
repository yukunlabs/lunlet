// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-20, AC-20.03; US-33, AC-33.05; US-36, AC-36.01, AC-36.03.
import Foundation
import LunletCore

/// The Block Kit layout of a completion notice, in the order of the Feishu card: a header with the agent and the
/// event, the session title, the quoted request, the reply in sections of at most 3,000 characters, any notes and
/// the reply line. Slack shows the time itself. It has no buttons, inputs or other interactive elements; a reply
/// is a message in the notice's thread.
enum SlackNoticeMessage {
    static let sectionLimit = 3_000
    static let blockLimit = 50
    static let headerLimit = 150

    /// `reply` adds the reply line: the invitation while open, otherwise the reply's state; nil shows no reply affordance.
    static func body(_ notice: SessionNotice, channel: String, reply: NoticeReplyState?) -> [String: Any] {
        let result = notice.result()
        let heading = notice.agentHeadline + " · " + notice.project
        var head: [[String: Any]] = [
            ["type": "header", "text": ["type": "plain_text", "emoji": false,
                                        "text": NoticeText.excerpt(heading, limit: headerLimit) ?? notice.agentHeadline]],
        ]
        if !notice.titleIsPlaceholder { head.append(context(escape(notice.title))) }
        if let request = notice.request { head.append(section("&gt; " + escape(request))) }
        var tail: [[String: Any]] = []
        let notes = notice.notes + [result.note].compactMap { $0 }
        if !notes.isEmpty { tail.append(context(notes.map(escape).joined(separator: "\n"))) }
        if let reply { tail.append(context(replyLine(reply, agent: notice.agent))) }
        // A finished turn's reply follows its request unlabeled; other events name what the session needs.
        let label = notice.resultLabel == "Result" ? "" : "*" + notice.resultLabel + "*\n"
        let available = blockLimit - head.count - tail.count
        let sections: [String]
        if let text = result.text {
            let fitted = NoticeText.fitting(text, alreadyShortened: result.shortened) {
                chunks(label + mrkdwn($0)).count <= available
            } ?? NoticeText.truncationNotice
            sections = chunks(label + mrkdwn(fitted))
        } else {
            sections = [label + escape(result.fallback)]
        }
        // The plain fallback is what a phone notification shows; it is never formatted or linked.
        let summary = NoticeText.excerpt(heading + (notice.request.map { " — " + $0 } ?? ""), limit: 300) ?? heading
        return ["channel": channel, "text": escape(summary), "mrkdwn": false, "parse": "none",
                "unfurl_links": false, "unfurl_media": false, "blocks": head + sections.map(section) + tail]
    }

    static func replyLine(_ state: NoticeReplyState, agent: String) -> String {
        guard let status = NoticeReplyText.status(state, agent: agent) else {
            return "_" + escape(NoticeReplyText.hint(.slack)) + "_"
        }
        return "*" + escape(status.label) + "* · " + escape(status.detail)
    }

    /// Minimal Markdown to mrkdwn: bold, italics, strikethrough, headings, bullets, rules and http(s) links
    /// are translated outside code; code keeps its text without a language hint. `&`, `<` and `>` are always
    /// escaped, so supplied text can never form a mention, channel link or command.
    static func mrkdwn(_ markdown: String) -> String {
        var fenced = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            if NoticeText.isFence(raw) { fenced.toggle(); return "```" }
            if fenced { return escape(String(raw)) }
            var line = String(raw)
            let indent = String(line.prefix(while: { $0 == " " }))
            line.removeFirst(indent.count)
            if line.range(of: #"^([-*_])( *\1){2,} *$"#, options: .regularExpression) != nil { return "──────────" }
            if let heading = line.range(of: #"^#{1,6} +"#, options: .regularExpression) {
                let title = inline(String(line[heading.upperBound...])).replacingOccurrences(of: "*", with: "")
                return title.isEmpty ? "" : "*" + title + "*"
            }
            if let bullet = line.range(of: #"^[-*+] +"#, options: .regularExpression) {
                return indent + "• " + inline(String(line[bullet.upperBound...]))
            }
            return indent + inline(line)
        }.joined(separator: "\n")
    }

    /// Splits text into section texts of at most `limit` UTF-16 units at line and word boundaries; a code
    /// block split across sections is closed and reopened.
    static func chunks(_ text: String, limit: Int = sectionLimit) -> [String] {
        var result: [String] = [], current = "", fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for piece in pieces(String(line), limit: limit - 8) {
                let isFence = piece == "```"
                let addition = (current.isEmpty ? "" : "\n") + piece
                if !current.isEmpty, current.utf16.count + addition.utf16.count + (fenced && !isFence ? 4 : 0) > limit {
                    if fenced {
                        result.append(current + "\n```")
                        if isFence { current = ""; fenced = false; continue }
                        current = "```\n" + piece
                    } else {
                        result.append(current); current = piece
                    }
                } else {
                    current += addition
                }
                if isFence { fenced.toggle() }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ line: String) -> String {
        let spans = line.split(separator: "`", omittingEmptySubsequences: false)
        let closed = spans.count % 2 == 1
        return spans.enumerated().map { index, span in
            let code = index % 2 == 1 && (closed || index < spans.count - 1)
            return code ? escape(String(span)) : emphasis(escape(String(span)))
        }.joined(separator: "`")
    }

    private static func emphasis(_ text: String) -> String {
        var value = text
        for (pattern, template) in emphasisRules {
            value = pattern.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
        }
        return value.replacingOccurrences(of: "\u{1}", with: "*")
    }

    private static func pieces(_ line: String, limit: Int) -> [String] {
        guard line.utf16.count > limit else { return [line] }
        var result: [String] = [], current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word)
            while word.utf16.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                let head = String(word.prefix(limit / 2))
                result.append(head); word.removeFirst(head.count)
            }
            let addition = (current.isEmpty ? "" : " ") + word
            if current.utf16.count + addition.utf16.count > limit { result.append(current); current = word }
            else { current += addition }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func section(_ text: String) -> [String: Any] {
        ["type": "section", "text": ["type": "mrkdwn", "text": text, "verbatim": true]]
    }
    private static func context(_ text: String) -> [String: Any] {
        ["type": "context", "elements": [["type": "mrkdwn", "text": text, "verbatim": true]]]
    }

    /// Verbatim text is never auto-linked, so bare web addresses are linked explicitly. Bold uses a
    /// placeholder so the single-asterisk italic rule cannot reread it.
    private static let emphasisRules: [(NSRegularExpression, String)] = [
        (#"!?\[([^\]|]+)\]\((https?://[^)\s|]+)\)"#, "<$2|$1>"),
        (#"(?<![<|\w])https?://[^\s<>|`]*[^\s<>|`.,;:!?)]"#, "<$0>"),
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "\u{1}$1\u{1}"),
        (#"__(?=\S)(.+?)(?<=\S)__"#, "\u{1}$1\u{1}"),
        (#"(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])"#, "_$1_"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "~$1~"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
