// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.04, AC-06.05; US-07, AC-07.01, AC-07.02, AC-07.04.
// Refs: US-08, AC-08.01, AC-08.03, AC-08.04; US-09, AC-09.01; US-10, AC-10.01, AC-10.02, AC-10.04; US-33, AC-33.05.
// Refs: US-05, AC-05.09.
import Foundation
import LunletCore

/// What a completion card's reply box shows: open for one reply, then that reply's progress or outcome,
/// or closed with the reason the card can no longer take one. Every state after `open` disables the box.
public enum CardReplyState: Equatable, Sendable {
    case open
    /// The owner's reply was accepted and is being handed to Codex.
    case received(String)
    /// Codex accepted the reply; the session record has not shown it yet.
    case submitted(String)
    case finished(ContinuationOutcome, String)
    /// No reply was sent from this card, and none can be.
    case closed(ContinuationRefusal)
}

public struct RenderedSessionCard: Sendable {
    public let delivery: FeishuCardDelivery
    public let form: CardForm?
    public let controlID: UUID?
}

public enum SessionCard {
    /// The card JSON stays at or below this size: under Feishu's 30 KB card limit and the delivery check,
    /// with room for a reply form appended later.
    static let budget = 24_000
    /// The header mark of every card: an AI assistant, from Feishu's colorful icon set.
    static let headerIcon = "ai-common_colorful"

    public static func form(for snapshot: SessionSnapshot) -> CardForm? {
        let notice = SessionNotice.prepare(snapshot)
        if notice.allowsFollowup { return .followup(field: "followup") }
        guard !notice.questions.isEmpty else { return nil }
        return .answers(notice.questions.enumerated().map { index, question in
            let kind: CardAnswerField.Kind
            switch question.kind {
            case .text: kind = .text
            case .singleChoice(let options): kind = .singleChoice(Set(options.map(\.value)))
            case .multipleChoice(let options): kind = .multipleChoice(Set(options.map(\.value)))
            }
            return CardAnswerField(name: "answer_\(index)", questionID: question.id, kind: kind)
        })
    }

    /// `reply` appends the completion card's reply box for one issued capability, shown in `replyState`;
    /// `control` is the question/follow-up form of the coordinator's own controls. A card carries at most one.
    public static func render(_ snapshot: SessionSnapshot, control: ContinuationControl? = nil,
                              reply: FeishuReplyCapability? = nil, replyState: CardReplyState = .open, now: Date = Date(),
                              calendar: Calendar = .current, locale: Locale = .current) throws -> RenderedSessionCard {
        let notice = SessionNotice.prepare(snapshot)
        let available = form(for: snapshot)
        let active = control != nil && available != nil
        guard !(active && reply != nil) else { throw FeishuBotFailure.invalidRequest }
        // Interactive components follow the notice, so adding a reply form never restructures it.
        var interaction: [[String: Any]] = []
        var tag: (String, String)?
        if let reply {
            guard reply.sessionID == snapshot.observation.sessionID else { throw FeishuBotFailure.invalidRequest }
            interaction += replyBox(reply, state: replyState, agent: notice.agent)
            tag = replyTag(replyState)
        }
        if active, let control {
            guard control.expiresAt.isFinite, control.expiresAt > 0 else { throw FeishuBotFailure.invalidRequest }
            var fields: [[String: Any]] = []
            if notice.allowsFollowup {
                fields.append(input(name: "followup", placeholder: "Add a follow-up for this conversation"))
            } else {
                for (index, question) in notice.questions.enumerated() {
                    fields.append(markdown(escaped(question.prompt)))
                    let name = "answer_\(index)"
                    switch question.kind {
                    case .text: fields.append(input(name: name, placeholder: "Your answer"))
                    case .singleChoice(let options), .multipleChoice(let options):
                        let multiple: Bool
                        if case .multipleChoice = question.kind { multiple = true } else { multiple = false }
                        fields.append([
                            "tag": multiple ? "multi_select_static" : "select_static", "name": name, "required": true,
                            "placeholder": plain("Choose an answer"),
                            "options": options.map { ["text": plain($0.label), "value": $0.value] as [String: Any] },
                        ])
                    }
                }
            }
            fields.append([
                "tag": "button", "name": "submit", "type": "primary", "text": plain("Send to this session"),
                "form_action_type": "submit", "behaviors": [["type": "callback", "value": ["lunlet_control": control.id.uuidString]]],
            ])
            interaction.append(["tag": "form", "name": "continuation", "elements": fields])
        }
        // Only a card that can never carry a reply box says so; a Feishu Codex card may gain one later, so it stays
        // silent rather than claim replies do not exist.
        if !active, reply == nil, snapshot.provider != .codex {
            interaction.append(markdown(grey(escaped(SessionNotice.repliesUnavailableFooter)), size: "notation",
                                        icon: ("info_outlined", "grey")))
        }
        let time = notice.eventTime(now: now, calendar: calendar, locale: locale)
        return RenderedSessionCard(delivery: try FeishuCardDelivery(cardJSON: card(notice, time: time, tag: tag, interaction: interaction)),
                                   form: active ? available : nil, controlID: active ? control?.id : nil)
    }

    /// A JSON 2.0 card in Feishu's own card idiom: a header tinted by the outcome,
    /// titled with the agent and the event, with the project, session and local time below and the reply state as a
    /// tag; the request in a tinted block; the reply in a bordered block named after the agent, with any notes kept
    /// beside it; then `interaction`. One accent color follows the tone and blocks sit 12 points apart. The reply is
    /// the agent's Markdown, shortened only when the card would exceed `budget`. Cards are shared (`update_multi`)
    /// so a reply box can be updated in place.
    static func card(_ notice: SessionNotice, time: String?, tag: (String, String)?, interaction: [[String: Any]]) throws -> Data {
        let result = notice.result()
        let color = accent(notice.tone)
        let subtitle = ([notice.project] + (notice.titleIsPlaceholder ? [] : [notice.title]) + [time].compactMap { $0 })
            .joined(separator: " · ")
        func compose(_ text: String?) throws -> Data {
            var elements: [[String: Any]] = []
            if let request = notice.request { elements.append(block("You asked", [markdown(escaped(request))], color: color)) }
            var body = [markdown(text.map(agentMarkdown) ?? escaped(result.fallback))]
            let notes = notice.notes + [result.note].compactMap { $0 }
            if !notes.isEmpty {
                body.append(markdown(grey(notes.map(escaped).joined(separator: "\n")), size: "notation", icon: ("info_outlined", "grey")))
            }
            // A finished turn's reply is the agent's own block; other events name what the session needs.
            elements.append(bordered(notice.resultLabel == "Result" ? notice.agent : notice.resultLabel, body, color: color))
            elements += interaction
            var header: [String: Any] = [
                "title": plain(notice.agentHeadline), "subtitle": plain(subtitle), "template": color,
                "icon": ["tag": "standard_icon", "token": headerIcon],
            ]
            if let tag { header["text_tag_list"] = [["tag": "text_tag", "text": plain(tag.0), "color": tag.1]] }
            let card: [String: Any] = [
                "schema": "2.0",
                // The chat list and system notification show this line instead of a generic card label.
                "config": ["update_multi": true, "width_mode": "default",
                           "summary": ["content": notice.agentHeadline + " · " + notice.project + (notice.request.map { ": " + $0 } ?? "")]],
                "header": header,
                "body": ["direction": "vertical", "padding": "12px 12px 20px 12px", "vertical_spacing": "12px", "elements": elements],
            ]
            return try JSONSerialization.data(withJSONObject: card, options: [.withoutEscapingSlashes])
        }
        guard let text = result.text else { return try compose(nil) }
        let fitted = NoticeText.fitting(text, alreadyShortened: result.shortened) { candidate in
            ((try? compose(candidate))?.count ?? .max) <= budget
        }
        return try compose(fitted ?? NoticeText.truncationNotice)
    }

    /// The reply box under `FeishuReplyCapability`'s callback contract: one plain-text input and one submit button whose
    /// callback value is exactly the capability's token, side by side like a message composer. After a reply, the box
    /// keeps the sent text, disables both controls and a tinted block below states the reply's progress.
    static func replyBox(_ reply: FeishuReplyCapability, state: CardReplyState, agent: String) -> [[String: Any]] {
        let sent: String?, status: (label: String, text: String, color: String, icon: String)?
        switch state {
        case .open: (sent, status) = (nil, nil)
        case .received(let text): (sent, status) = (text, ("Received", "sending to \(agent)…", "grey", "send_outlined"))
        case .submitted(let text): (sent, status) = (text, ("Sent", "waiting for \(agent) to start", "grey", "send_outlined"))
        case .finished(let outcome, let text):
            switch outcome {
            case .delivered: (sent, status) = (text, ("Delivered", "\(agent) is continuing on your Mac", "green", "done_outlined"))
            case .notConfirmed:
                (sent, status) = (text, ("Not confirmed", "\(agent) hasn't confirmed it. Check your Mac; Lunlet won't send it again.",
                                         "orange", "warning_outlined"))
            case .failed: (sent, status) = (text, ("Not sent", "Continue on your Mac.", "red", "warning_outlined"))
            case .refused(let reason): (sent, status) = (text, ("Not sent", reason.explanation, "orange", "warning_outlined"))
            }
        case .closed(let reason): (sent, status) = (nil, ("Replies closed", reason.explanation, "grey", "info_outlined"))
        }
        let open = state == .open
        var field: [String: Any] = [
            "tag": "input", "name": FeishuReplyCapability.fieldName, "width": "fill",
            "input_type": "multiline_text", "rows": 1, "auto_resize": true, "max_rows": 6,
            "max_length": FeishuReplyCapability.maximumCharacters,
            "placeholder": plain(open ? SessionNotice.replyWindowHint : "Replies closed"),
        ]
        var button: [String: Any] = [
            "tag": "button", "name": FeishuReplyCapability.buttonName, "type": "primary_filled",
            "text": plain(sent == nil ? "Send" : "Sent"), "form_action_type": "submit",
            "behaviors": [["type": "callback", "value": reply.callbackValue]],
        ]
        // Feishu refuses an input that is both required and disabled (230099/10002), so only the open box is required.
        if open { field["required"] = true } else { field["disabled"] = true; button["disabled"] = true }
        if let sent { field["default_value"] = sent }
        let composer: [String: Any] = ["tag": "column_set", "flex_mode": "none", "horizontal_spacing": "8px", "columns": [
            ["tag": "column", "width": "weighted", "weight": 1, "vertical_align": "center", "elements": [field]] as [String: Any],
            ["tag": "column", "width": "auto", "vertical_align": "center", "elements": [button]] as [String: Any],
        ]]
        var elements: [[String: Any]] = [["tag": "form", "name": FeishuReplyCapability.formName, "elements": [composer]]]
        if let status {
            elements.append(["tag": "column_set", "flex_mode": "none", "columns": [[
                "tag": "column", "width": "weighted", "weight": 1, "background_style": status.color + "-50", "padding": "10px 12px",
                "elements": [markdown("**<font color='\(status.color)'>" + status.label + "</font>** · " + escaped(status.text),
                                      icon: (status.icon, status.color))],
            ] as [String: Any]]])
        }
        return elements
    }

    /// The header tag naming the reply's state, so the chat list shows it at a glance; none before a reply.
    static func replyTag(_ state: CardReplyState) -> (String, String)? {
        switch state {
        case .open, .closed: nil
        case .received: ("Sending", "neutral")
        case .submitted: ("Sent", "neutral")
        case .finished(.delivered, _): ("Replied", "green")
        case .finished(.notConfirmed, _): ("Unconfirmed", "orange")
        case .finished(.failed, _): ("Not sent", "red")
        case .finished(.refused, _): ("Not sent", "orange")
        }
    }

    /// The accent of a card: its header tint and the color of its block labels, borders and backgrounds. Only evidence
    /// makes a turn green or red; a normal end without an explicit outcome keeps the product's indigo.
    static func accent(_ tone: SessionNotice.Tone) -> String {
        switch tone {
        case .succeeded: "green"
        case .finished: "indigo"
        case .failed: "red"
        case .neutral: "grey"
        case .attention: "orange"
        }
    }

    /// A tinted block whose first line is its bold label in the accent color.
    static func block(_ label: String, _ elements: [[String: Any]], color: String) -> [String: Any] {
        ["tag": "column_set", "flex_mode": "none", "columns": [[
            "tag": "column", "width": "weighted", "weight": 1, "background_style": color + "-50", "padding": "12px",
            "vertical_spacing": "2px", "elements": [heading(label, color: color)] + elements,
        ] as [String: Any]]]
    }

    /// A white block with a thin tinted border and rounded corners, labeled like `block`.
    static func bordered(_ label: String, _ elements: [[String: Any]], color: String) -> [String: Any] {
        ["tag": "interactive_container", "width": "fill", "has_border": true, "border_color": color + "-100",
         "corner_radius": "8px", "padding": "12px", "vertical_spacing": "4px", "elements": [heading(label, color: color)] + elements]
    }

    private static func heading(_ label: String, color: String) -> [String: Any] {
        markdown("**<font color='\(color)'>" + escaped(label) + "</font>**")
    }

    /// Agent Markdown stays formatted. Outside code, `<` becomes an entity so supplied text can never open a
    /// mention, font, link or other card tag; code keeps its characters.
    static func agentMarkdown(_ text: String) -> String {
        var fenced = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if NoticeText.isFence(line) { fenced.toggle(); return String(line) }
            if fenced { return String(line) }
            let spans = line.split(separator: "`", omittingEmptySubsequences: false)
            let closed = spans.count % 2 == 1
            return spans.enumerated().map { index, span in
                let code = index % 2 == 1 && (closed || index < spans.count - 1)
                return code ? String(span) : span.replacingOccurrences(of: "<", with: "&#60;")
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }

    /// Plain text inside a markdown component: syntax and tag characters become numeric entities, the escape
    /// form the card markdown documents, so supplied text cannot create formatting, mentions or links.
    static func escaped(_ content: String) -> String {
        var value = ""
        for (index, character) in content.enumerated() {
            switch character {
            case "<": value += "&#60;"
            case ">": value += "&#62;"
            case "*": value += "&#42;"
            case "_": value += "&#95;"
            case "~": value += "&#126;"
            case "`": value += "&#96;"
            case "[": value += "&#91;"
            case "]": value += "&#93;"
            case "\\": value += "&#92;"
            // A leading heading or list marker would turn the line into structure.
            case "#" where index == 0, "-" where index == 0, "+" where index == 0: value += "&#\(character.asciiValue!);"
            default: value.append(character)
            }
        }
        return value
    }

    private static func plain(_ content: String) -> [String: String] { ["tag": "plain_text", "content": content] }
    private static func grey(_ content: String) -> String { "<font color='grey'>" + content + "</font>" }
    /// `icon` prefixes the text with a library icon (token, color).
    private static func markdown(_ content: String, size: String? = nil, icon: (String, String)? = nil) -> [String: Any] {
        var element: [String: Any] = ["tag": "markdown", "content": content]
        element["text_size"] = size
        if let icon { element["icon"] = ["tag": "standard_icon", "token": icon.0, "color": icon.1] }
        return element
    }
    private static func input(name: String, placeholder: String) -> [String: Any] {
        ["tag": "input", "name": name, "required": true, "placeholder": plain(placeholder),
         "input_type": "multiline_text", "rows": 3, "max_length": 1_000]
    }
}
