// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-20, AC-20.03; US-33, AC-33.05; US-10, AC-10.01; US-05, AC-05.09.
// Opt-in owner preview of the completion notice on every channel, built from the payloads Lunlet would send for
// synthetic sessions. The page only approximates each messenger's styling; it is not delivery evidence.
import AppKit
import Foundation
import Testing
import WebKit
import LunletCore
@testable import LunletFeishu
@testable import LunletMessaging

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_NOTICE_PREVIEW_DIR"] != nil))
@MainActor struct NoticePreviewRenderTests {
    private struct Scenario { let name: String; let caption: String; let snapshot: SessionSnapshot }

    private static func scenarios(now: Date) -> [Scenario] {
        func snapshot(_ phase: SessionPhase, project: String, title: String? = nil, reply: String?, outcome: TaskCue.Outcome,
                      request: String?, limitations: [String] = [], provider: SessionProvider = .codex) -> SessionSnapshot {
            SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: phase),
                            project: project, title: title, publicConclusion: reply, limitations: limitations, outcome: outcome,
                            activityConfirmed: true, lastActivityAt: now.addingTimeInterval(-40), localPreview: request,
                            provider: provider)
        }
        let reply = """
        ## Fixed the session card layout

        The completion card now shows the request and the final reply instead of a bare session ID.

        - `SessionNotice` builds the header, request, result and footer once for every channel.
        - Long replies are cut at a word boundary and end with a pointer back to the Mac.
        - Markdown from the agent stays readable; supplied tags such as <at id=all> stay inert.

        ```swift
        let notice = SessionNotice.prepare(snapshot)
        let card = try SessionCard.render(snapshot)
        ```

        Tests: `scripts/test-core.sh feishu` and `messaging` pass. See [Feishu card docs](https://open.feishu.cn/document/) for the schema.
        """
        return [
            Scenario(name: "succeeded", caption: "A finished Codex turn with its request and full Markdown reply",
                     snapshot: snapshot(.idle(completedTurnID: "t1"), project: "lunlet", reply: reply, outcome: .succeeded,
                                        request: "Redesign the completion card so it carries the gist of the work and looks polished on Feishu, Slack and Telegram")),
            Scenario(name: "finished-unknown", caption: "Codex finished without an outcome signal and no reply was captured",
                     snapshot: snapshot(.idle(completedTurnID: "t2"), project: "lunlet", reply: nil, outcome: .unknown,
                                        request: "Run the release checklist")),
            Scenario(name: "failed", caption: "A failed Claude Code turn with a limitation",
                     snapshot: snapshot(.idle(completedTurnID: "t3"), project: "lunlet-site", title: "Landing page polish",
                                        reply: "The build failed: `npm run build` exited with code 1 because `style.css` has an unclosed block on line 214.",
                                        outcome: .failed, request: "Tighten the hero spacing", limitations: ["Tests were not run."],
                                        provider: .claude)),
            Scenario(name: "long", caption: "A long reply: Feishu and Slack show it whole; Telegram's one message ends with a pointer to the Mac",
                     snapshot: snapshot(.idle(completedTurnID: "t4"), project: "lunlet", title: "Release notes",
                                        reply: (1...14).map { "### Step \($0)\n\nChecked the synthetic module \($0), updated its tests and recorded the result. "
                                            + String(repeating: "The change keeps every existing boundary intact. ", count: 6) }.joined(separator: "\n\n"),
                                        outcome: .unknown, request: "Draft the release notes for this week")),
            Scenario(name: "approval", caption: "An execution approval waiting on the Mac",
                     snapshot: snapshot(.approval, project: "lunlet", reply: nil, outcome: .unknown,
                                        request: "Clean the build cache and rebuild")),
        ]
    }

    @Test func renderTheNoticeOnEveryChannel() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_NOTICE_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var rows: [String] = []
        for scenario in Self.scenarios(now: now) {
            let notice = SessionNotice.prepare(scenario.snapshot)
            let card = try SessionCard.render(scenario.snapshot)
            // Idle Codex turns show the reply invitation Slack and Telegram carry while the Mac is locked.
            let reply: NoticeReplyState? = scenario.snapshot.provider == .codex && notice.allowsFollowup ? .open : nil
            let slack = SlackNoticeMessage.body(notice, channel: "D0SYNTHETIC", reply: reply)
            let telegram = TelegramNoticeMessage.html(notice, reply: reply)
            let row = """
            <section class="row"><h2>\(Self.escape(scenario.caption))</h2><div class="channels">
            <div class="channel"><h3>Feishu / Lark</h3>\(try Self.feishu(card.delivery.content))</div>
            <div class="channel"><h3>Slack</h3>\(try Self.slack(slack))</div>
            <div class="channel"><h3>Telegram</h3>\(Self.telegram(telegram))</div>
            </div></section>
            """
            rows.append(row)
            let page = Self.page([row])
            try page.write(to: directory.appendingPathComponent("notice-\(scenario.name).html"), atomically: true, encoding: .utf8)
            try await Self.snapshot(page, to: directory.appendingPathComponent("notice-\(scenario.name).png"))
        }
        // The Feishu reply box for one finished Codex turn: open, after one reply, and after the Mac unlocked.
        let codex = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                       phase: .idle(completedTurnID: "t9")),
                                    project: "lunlet", publicConclusion: "Done. The parser keeps Unicode, and `scripts/test-core.sh core` passes.",
                                    outcome: .unknown, activityConfirmed: true, lastActivityAt: now.addingTimeInterval(-40),
                                    localPreview: "Make the parser keep Unicode")
        let capability = FeishuReplyCapability(token: UUID(), sessionID: codex.observation.sessionID, turnID: "t9",
                                               expiresAt: now.addingTimeInterval(600))
        let states: [(String, CardReplyState)] = [("Open", .open), ("After one reply", .finished(.delivered, "Now run the full suite")),
                                                  ("After unlocking", .closed(.replyWindowClosed))]
        let boxes = try states.map { title, state in
            "<div class=\"channel\"><h3>\(title)</h3>"
                + (try Self.feishu(SessionCard.render(codex, reply: capability, replyState: state, now: now).delivery.content)) + "</div>"
        }.joined()
        let replies = "<section class=\"row\"><h2>Feishu reply box for a finished Codex turn</h2><div class=\"channels\">\(boxes)</div></section>"
        rows.append(replies)
        try await Self.snapshot(Self.page([replies]), to: directory.appendingPathComponent("notice-reply-box.png"))
        let page = Self.page(rows)
        try page.write(to: directory.appendingPathComponent("notice-preview.html"), atomically: true, encoding: .utf8)
        try await Self.snapshot(page, to: directory.appendingPathComponent("notice-preview.png"))
    }

    // MARK: - Channel approximations

    private static func feishu(_ json: String) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let header = try #require(object["header"] as? [String: Any])
        let template = header["template"] as? String ?? "grey"
        let title = (header["title"] as? [String: Any])?["content"] as? String ?? ""
        let subtitle = (header["subtitle"] as? [String: Any])?["content"] as? String ?? ""
        let tags = (header["text_tag_list"] as? [[String: Any]] ?? []).map { tag in
            "<span class=\"tag tag-\(tag["color"] as? String ?? "blue")\">"
                + escape((tag["text"] as? [String: Any])?["content"] as? String ?? "") + "</span>"
        }.joined()
        let elements = (object["body"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []
        let mark = icon(header["icon"] as? [String: Any])
        return """
        <div class="chat feishu"><div class="sender"><span class="avatar">L</span>Lunlet</div>
        <div class="card"><div class="fs-header fs-\(template)"><div class="fs-title">\(mark)\(escape(title))\(tags)</div>
        <div class="fs-subtitle">\(escape(subtitle))</div></div><div class="fs-body">\(elements.map(feishuElement).joined())</div></div>
        <div class="size">\(json.utf8.count) bytes of card JSON</div></div>
        """
    }

    private static func feishuElement(_ element: [String: Any]) -> String {
        let children = (element["elements"] as? [[String: Any]] ?? []).map(feishuElement).joined()
        switch element["tag"] as? String {
        case "hr": return "<hr>"
        case "interactive_container":
            return "<div class=\"box bd-\(element["border_color"] as? String ?? "grey")\">\(children)</div>"
        case "markdown":
            var content = element["content"] as? String ?? "", color = ""
            if let match = content.firstMatch(of: /^<font color='(\w+)'>([\s\S]*)<\/font>$/) {
                color = " fc-" + match.1; content = String(match.2)
            }
            // Inline tinted spans, such as block labels, keep their color through escaping as private-use markers.
            content = content.replacingOccurrences(of: #"<font color='([\w-]+)'>(.+?)</font>"#, with: "\u{E500}$1\u{E501}$2\u{E502}",
                                                   options: .regularExpression)
            content = content.replacingOccurrences(of: #"</?font[^>]*>"#, with: "", options: .regularExpression)
            let note = element["text_size"] as? String == "notation" ? " note" : ""
            let prefix = icon(element["icon"] as? [String: Any])
            return "<div class=\"md\(note)\(color)\(prefix.isEmpty ? "" : " with-icon")\">\(prefix)<div>" + feishuMarkdown(content) + "</div></div>"
        case "column_set":
            let background = (element["background_style"] as? String).map { " bg-" + $0 } ?? ""
            let columns = (element["columns"] as? [[String: Any]] ?? []).map { column in
                let tint = (column["background_style"] as? String).map { " bg-" + $0 } ?? ""
                return "<div class=\"col\(column["width"] as? String == "auto" ? " auto" : "")\(tint)\">"
                    + (column["elements"] as? [[String: Any]] ?? []).map(feishuElement).joined() + "</div>"
            }.joined()
            return "<div class=\"cs\(background)\">\(columns)</div>"
        case "form": return "<div class=\"form\">\(children)</div>"
        case "input":
            let value = element["default_value"] as? String
            let placeholder = (element["placeholder"] as? [String: Any])?["content"] as? String ?? ""
            let disabled = element["disabled"] as? Bool == true ? " disabled" : ""
            return "<div class=\"input\(disabled)\(value == nil ? " ph" : "")\">" + escape(value ?? placeholder) + "</div>"
        case "button":
            let disabled = element["disabled"] as? Bool == true ? " disabled" : ""
            return "<div class=\"btn\(disabled)\">" + escape((element["text"] as? [String: Any])?["content"] as? String ?? "") + "</div>"
        default: return "<div class=\"note\">[\(escape(element["tag"] as? String ?? "element"))]</div>"
        }
    }

    /// Line icons approximating the Feishu icon library tokens the card uses.
    private static func icon(_ value: [String: Any]?) -> String {
        guard let value, let token = value["token"] as? String else { return "" }
        let paths = [
            "code_outlined": "M5 4 1 8l4 4M11 4l4 4-4 4", "member_outlined": "M5 5a3 3 0 1 0 6 0a3 3 0 1 0-6 0M2 15c0-3.3 2.7-5 6-5s6 1.7 6 5",
            "time_outlined": "M1.5 8a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0-13 0M8 4.5V8l2.5 1.5",
            "info_outlined": "M1.5 8a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0-13 0M8 7v4.5M8 4.6v.4", "send_outlined": "M2 7.5 14 2l-5 12-2-5z",
            "done_outlined": "M3 8.5 6.5 12 13 4.5", "warning_outlined": "M8 2 15 14H1zM8 6.5v3.5M8 11.6v.4",
        ]
        if token.hasSuffix("_colorful") {
            return "<svg class=\"ic colorful\" viewBox=\"0 0 16 16\"><path d=\"M8 1.5 9.7 6.3 14.5 8 9.7 9.7 8 14.5 6.3 9.7 1.5 8 6.3 6.3z\"/></svg>"
        }
        let color = value["color"] as? String ?? "grey"
        return "<svg class=\"ic fc-\(color)\" viewBox=\"0 0 16 16\"><path d=\"\(paths[token] ?? "")\"/></svg>"
    }

    /// Markdown as the card shows it: numeric entities stay literal characters, never syntax.
    private static func feishuMarkdown(_ markdown: String) -> String {
        var text = markdown
        while let range = text.range(of: #"&#[0-9]{2,3};"#, options: .regularExpression) {
            let code = UInt32(text[range].dropFirst(2).dropLast()) ?? 63
            text.replaceSubrange(range, with: String(Character(UnicodeScalar(0xE000 + code)!)))
        }
        var html = "", fenced = false, list = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if NoticeText.isFence(Substring(line)) {
                if list { html += "</ul>"; list = false }
                html += fenced ? "</code></pre>" : "<pre><code>"; fenced.toggle(); continue
            }
            if fenced { html += restore(escape(line)) + "\n"; continue }
            if let bullet = line.range(of: #"^\s*[-*+] +"#, options: .regularExpression) {
                if !list { html += "<ul>"; list = true }
                html += "<li>" + inline(String(line[bullet.upperBound...])) + "</li>"; continue
            }
            if list { html += "</ul>"; list = false }
            if let heading = line.range(of: #"^#{1,6} +"#, options: .regularExpression) {
                html += "<h4>" + inline(String(line[heading.upperBound...])) + "</h4>"
            } else if line.isEmpty { html += "<div class=\"gap\"></div>" } else { html += "<div>" + inline(line) + "</div>" }
        }
        if list { html += "</ul>" }
        if fenced { html += "</code></pre>" }
        return html
    }

    private static func inline(_ line: String) -> String {
        let spans = line.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        return spans.enumerated().map { index, span in
            if index % 2 == 1, index < spans.count - 1 || spans.count % 2 == 1 { return "<code>" + restore(escape(span)) + "</code>" }
            var value = escape(span)
            for (pattern, template) in [(#"\*\*(.+?)\*\*"#, "<b>$1</b>"), (#"\*(.+?)\*"#, "<i>$1</i>"), (#"~~(.+?)~~"#, "<s>$1</s>"),
                                        (#"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")] {
                value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            value = value.replacingOccurrences(of: "\u{E500}([\\w-]+)\u{E501}(.+?)\u{E502}", with: "<span class=\"fc-$1\">$2</span>",
                                               options: .regularExpression)
            return restore(value)
        }.joined()
    }

    /// Entity placeholders become the characters they stand for, escaped for this page.
    private static func restore(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> String in
            (0xE000...0xE3FF).contains(scalar.value) ? escape(String(Character(UnicodeScalar(scalar.value - 0xE000)!))) : String(scalar)
        }.joined())
    }

    private static func slack(_ body: [String: Any]) throws -> String {
        let blocks = try #require(body["blocks"] as? [[String: Any]])
        let html = blocks.map { block -> String in
            let text = (block["text"] as? [String: Any])?["text"] as? String
            switch block["type"] as? String {
            case "header": return "<div class=\"sl-header\">" + escape(text ?? "") + "</div>"
            case "context":
                let value = ((block["elements"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return "<div class=\"sl-context\">" + slackMrkdwn(value) + "</div>"
            case "divider": return "<hr>"
            default: return "<div class=\"sl-section\">" + slackMrkdwn(text ?? "") + "</div>"
            }
        }.joined()
        return """
        <div class="chat slack"><div class="sl-message"><span class="avatar sq">L</span><div><div class="sender">Lunlet <span class="app">APP</span></div>
        \(html)</div></div><div class="size">\(blocks.count) blocks · fallback: \(escape(body["text"] as? String ?? ""))</div></div>
        """
    }

    /// mrkdwn arrives with `&`, `<` and `>` already escaped, so only its own syntax is translated.
    private static func slackMrkdwn(_ text: String) -> String {
        var html = "", fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "```" { html += fenced ? "</code></pre>" : "<pre><code>"; fenced.toggle(); continue }
            if fenced { html += line + "\n"; continue }
            var value = line
            for (pattern, template) in [(#"<(https?://[^|>]+)\|([^>]+)>"#, "<a href=\"$1\">$2</a>"), (#"<(https?://[^>|]+)>"#, "<a href=\"$1\">$1</a>"),
                                        (#"`([^`]+)`"#, "<code>$1</code>"), (#"(?<![\w*])\*(\S(?:.*?\S)?)\*(?![\w*])"#, "<b>$1</b>"),
                                        (#"(?<![\w])_(\S(?:.*?\S)?)_(?![\w])"#, "<i>$1</i>"), (#"~(\S(?:.*?\S)?)~"#, "<s>$1</s>")] {
                value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            html += value.hasPrefix("&gt; ") ? "<blockquote>" + value.dropFirst(5) + "</blockquote>" : "<div>" + (value.isEmpty ? "&nbsp;" : value) + "</div>"
        }
        if fenced { html += "</code></pre>" }
        return html
    }

    /// Telegram's quote and code blocks take the line break that follows them.
    private static func telegram(_ html: String) -> String {
        let shown = html.replacingOccurrences(of: "</blockquote>\n", with: "</blockquote>").replacingOccurrences(of: "</pre>\n", with: "</pre>")
        return """
        <div class="chat telegram"><div class="tg-bubble">\(shown)<span class="tg-time">16:52</span></div>
        <div class="size">\(html.utf16.count) of 4,096 characters</div></div>
        """
    }

    private static func page(_ rows: [String]) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Lunlet completion notice preview</title><style>
        body{margin:0;padding:28px;background:#eef0f4;font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:#1f2329}
        h1{font-size:20px;margin:0 0 4px} .lead{color:#646a73;margin:0 0 20px}
        .row{margin-bottom:28px} .row h2{font-size:15px;margin:0 0 10px;color:#3b4047}
        .channels{display:grid;grid-template-columns:repeat(3,400px);gap:22px;align-items:start}
        .channel h3{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#8f959e;margin:0 0 8px}
        .chat{border-radius:14px;padding:14px;box-shadow:0 1px 3px rgba(0,0,0,.08)} .size{font-size:11px;color:#8f959e;margin-top:8px}
        .avatar{display:inline-flex;width:28px;height:28px;border-radius:50%;background:#6c5ce7;color:#fff;align-items:center;justify-content:center;font-weight:600;margin-right:8px;flex:none}
        .avatar.sq{border-radius:6px} .sender{display:flex;align-items:center;font-weight:600;margin-bottom:8px}
        .feishu{background:#f5f6f7} .card{background:#fff;border-radius:10px;overflow:hidden;border:1px solid #dee0e3}
        .fs-header{padding:12px 14px;color:#fff} .fs-title{font-size:16px;font-weight:600} .fs-subtitle{font-size:13px;opacity:.9;margin-top:2px}
        .fs-green{background:linear-gradient(90deg,#2ea121,#45b03a)} .fs-red{background:linear-gradient(90deg,#d83931,#e5534b)}
        .fs-grey{background:linear-gradient(90deg,#646a73,#80868f)} .fs-orange{background:linear-gradient(90deg,#de7802,#f08c1a)}
        .fs-indigo{background:linear-gradient(90deg,#4954e6,#5b67ea)} .ic.colorful{fill:#ffd166;stroke:#f08c1a;stroke-width:1}
        .col[class*=" bg-"]{border-radius:8px;padding:12px} .col[class*=" bg-"] .md{margin:0 0 2px} .col[class*=" bg-"] .md:last-child{margin:0}
        .col.bg-indigo-50{background:#f0f1ff} .col.bg-green-50{background:#eaf8e8} .col.bg-grey-50{background:#f5f6f7}
        .col.bg-orange-50{background:#fff5e6} .col.bg-red-50{background:#fdeceb}
        .box{border:1px solid #dee0e3;border-radius:8px;padding:12px;margin:0 0 10px} .box .md{margin:0 0 4px} .box .md:last-child{margin:0}
        .box.bd-indigo-100{border-color:#c8ccff} .box.bd-green-100{border-color:#c0ebb9} .box.bd-red-100{border-color:#f7c5c3}
        .box.bd-orange-100{border-color:#fbd9a9} .box.bd-grey-100{border-color:#dee0e3}
        span.fc-indigo{color:#4954e6} span.fc-green{color:#2ea121} span.fc-grey{color:#8f959e} span.fc-orange{color:#de7802} span.fc-red{color:#d83931}
        .fs-default{background:#fff;color:#1f2329;padding-bottom:4px} .fs-default .fs-subtitle{color:#646a73;opacity:1}
        .tag{display:inline-block;font-size:12px;font-weight:500;border-radius:4px;padding:1px 6px;margin-left:8px;vertical-align:2px}
        .tag-indigo{background:#e0e9ff;color:#3c4fbb} .tag-green{background:#d9f5d6;color:#237b19} .tag-red{background:#fde2e2;color:#c02a26}
        .tag-orange{background:#feead2;color:#b2600b} .tag-neutral{background:#eff0f1;color:#51565d}
        .cs{display:flex;gap:8px;align-items:center;margin:0 0 10px} .col{flex:1;min-width:0} .col.auto{flex:none}
        .form .cs{margin:0} .form{margin:0 0 8px}
        .input{border:1px solid #d0d3d6;border-radius:6px;padding:6px 10px;min-height:20px;background:#fff}
        .input.ph{color:#8f959e} .input.disabled{background:#f5f6f7;color:#8f959e}
        .btn{background:#3370ff;color:#fff;border-radius:6px;padding:6px 16px;font-weight:500}
        .btn.disabled{background:#e4e5e7;color:#a8abb0}
        .ic{width:15px;height:15px;flex:none;fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round;margin-right:6px}
        .fs-title .ic{width:18px;height:18px;vertical-align:-3px;margin-right:8px}
        .md.with-icon{display:flex;align-items:flex-start} .md.with-icon .ic{margin-top:3px} .md.note.with-icon .ic{margin-top:2px;width:13px;height:13px}
        .ic.fc-grey{color:#8f959e} .ic.fc-green{color:#2ea121} .ic.fc-orange{color:#de7802} .ic.fc-red{color:#d83931} .ic.fc-indigo{color:#4954e6}
        .md.fc-grey{color:#8f959e} .md.fc-green{color:#2ea121} .md.fc-orange{color:#de7802} .md.fc-red{color:#d83931}
        .fs-body{padding:12px 14px} .md{margin:0 0 10px} .md h4{margin:6px 0 4px;font-size:15px} .md ul{margin:4px 0;padding-left:20px}
        .md .gap{height:8px} .note{font-size:12px;color:#8f959e} hr{border:0;border-top:1px solid #dee0e3;margin:10px 0}
        pre{background:#f2f3f5;border-radius:6px;padding:8px 10px;overflow:hidden;white-space:pre-wrap;font:12px/1.4 Menlo,monospace;margin:6px 0}
        code{font:12px Menlo,monospace;background:#f2f3f5;border-radius:4px;padding:1px 4px} pre code{background:none;padding:0}
        a{color:#3370ff;text-decoration:none}
        .slack{background:#fff} .sl-message{display:flex;align-items:flex-start} .app{font-size:10px;background:#e8e8e8;color:#616061;border-radius:3px;padding:1px 4px;margin-left:6px}
        .sl-header{font-size:17px;font-weight:700;margin:2px 0 4px} .sl-context{font-size:12px;color:#616061;margin:2px 0 6px}
        .sl-section{margin:6px 0} .slack blockquote{margin:2px 0;padding-left:10px;border-left:4px solid #dddddd;color:#1d1c1d}
        .slack a{color:#1264a3}
        .telegram{background:#d5e4c3 linear-gradient(135deg,#cfe1bd,#e3edd0)} .tg-bubble{background:#fff;border-radius:12px 12px 12px 4px;padding:8px 11px 18px;white-space:pre-wrap;position:relative;box-shadow:0 1px 1px rgba(0,0,0,.1)}
        .tg-bubble blockquote{margin:2px 0;padding:2px 8px;border-left:3px solid #3390ec;background:#eef5fd;border-radius:4px;white-space:pre-wrap}
        .tg-time{position:absolute;right:10px;bottom:4px;font-size:11px;color:#8aa08a}
        </style></head><body><h1>Lunlet completion notice preview</h1>
        <p class="lead">Synthetic sessions only. Each column is built from the exact payload Lunlet would send; the styling only approximates each messenger.</p>
        \(rows.joined(separator: "\n"))</body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Offscreen WebKit snapshot

    private static func snapshot(_ html: String, to url: URL) async throws {
        let width: CGFloat = 1_330
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let loader = PageLoader()
        view.navigationDelegate = loader
        view.loadHTMLString(html, baseURL: nil)
        try await loader.wait()
        let height = (try await view.evaluateJavaScript("document.documentElement.scrollHeight") as? NSNumber)?.doubleValue ?? 900
        window.setContentSize(CGSize(width: width, height: height))
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        try await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let image = try await view.takeSnapshot(configuration: configuration)
        let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }
}

@MainActor private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?
    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    private func finish(_ value: Result<Void, any Error>) {
        guard result == nil else { return }
        result = value; continuation?.resume(with: value); continuation = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
}
