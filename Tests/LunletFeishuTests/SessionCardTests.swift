// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02, AC-06.04, AC-06.05; US-07, AC-07.01, AC-07.02, AC-07.04.
// Refs: US-08, AC-08.01, AC-08.03; US-09, AC-09.01; US-10, AC-10.01, AC-10.04; US-33, AC-33.05; US-05, AC-05.09.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

struct SessionCardTests {
    private func snapshot(_ phase: SessionPhase) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: phase),
                        project: "Lunlet", title: "Parser", publicConclusion: "Preserved café and Unicode.")
    }

    private func router(for observation: ObservedSession, connection: UUID) async -> CardActionRouter {
        let router = CardActionRouter(elapsed: { 0 }, wallTime: { CardCallbackFixture.date })
        await router.setAccess(.init(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true),
                               connectionID: connection)
        await router.observe(observation)
        return router
    }

    // Refs: US-33, AC-33.05.
    @Test func claudeCompletionCardsIdentifyClaudeAndOfferNoReplyControls() throws {
        let claude = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified,
                                                        phase: .idle(completedTurnID: "turn")), project: "Lunlet",
                                     turnID: "turn", activityConfirmed: true, provider: .claude)
        #expect(SessionCard.form(for: claude) == nil)
        let rendered = try SessionCard.render(claude)
        let json = try JSONSerialization.jsonObject(with: Data(rendered.delivery.content.utf8)) as! [String: Any]
        let header = try #require(json["header"] as? [String: Any])
        #expect((header["title"] as? [String: Any])?["content"] as? String == "Claude Code finished")
        #expect((header["subtitle"] as? [String: Any])?["content"] as? String == "Lunlet")
        #expect(rendered.delivery.content.contains(SessionNotice.repliesUnavailableFooter))
        #expect(!rendered.delivery.content.contains("form_action_type") && rendered.form == nil && rendered.controlID == nil)
        #expect(!rendered.delivery.content.contains("Mobile input is unavailable"))
    }

    @Test func aRenderedFollowupUsesOnlyItsOpaqueControlAndSubmitsThroughTheRouter() async throws {
        let snapshot = snapshot(.idle(completedTurnID: "turn_private")), connection = UUID()
        let router = await router(for: snapshot.observation, connection: connection)
        let form = try #require(SessionCard.form(for: snapshot))
        let control = try #require(await router.prepare(sessionID: snapshot.observation.sessionID, form: form))
        let rendered = try SessionCard.render(snapshot, control: control)
        let json = try JSONSerialization.jsonObject(with: Data(rendered.delivery.content.utf8)) as! [String: Any]
        #expect(json["schema"] as? String == "2.0")
        #expect(rendered.form == form && rendered.controlID == control.id)
        #expect(rendered.delivery.content.contains("form_action_type"))
        #expect(!rendered.delivery.content.contains("turn_private"))
        #expect(!rendered.delivery.content.contains(snapshot.observation.sessionID.uuidString))
        let receipt = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic", applicationID: "cli_synthetic",
                                          ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        let callback = try CardCallbackFixture.data(control: control.id, values: ["followup": "Keep the original context"])
        guard case .received(let action) = await router.handle(callback, connectionID: connection) else {
            Issue.record("The generated form must round-trip through authorization"); return
        }
        #expect(action.session == snapshot.observation)
        #expect(action.input == .followup("Keep the original context"))
    }

    @Test func textSingleAndMultipleChoicesKeepTheirExactQuestionMappings() async throws {
        let observation = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
            phase: .question(turnID: "turn", requestID: "request", itemID: "item", questionIDs: ["a", "b", "c"], purpose: .ordinary))
        let snapshot = SessionSnapshot(observation: observation, project: "Lunlet", title: "Build choice", questions: [
            .init(id: "a", prompt: "What should change?", kind: .text),
            .init(id: "b", prompt: "Build?", kind: .singleChoice([.init(value: "fast", label: "Fast")])),
            .init(id: "c", prompt: "Checks?", kind: .multipleChoice([.init(value: "unit", label: "Unit")])),
        ])
        let connection = UUID(), router = await router(for: observation, connection: connection)
        let form = try #require(SessionCard.form(for: snapshot))
        let control = try #require(await router.prepare(sessionID: observation.sessionID, form: form))
        let card = try SessionCard.render(snapshot, control: control)
        #expect(card.delivery.content.contains("select_static") && card.delivery.content.contains("multi_select_static"))
        #expect(await router.bind(controlID: control.id, receipt: .init(messageID: "om_synthetic", chatID: "oc_synthetic",
            applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")))
        let data = try CardCallbackFixture.data(control: control.id, values: ["answer_0": "Parser", "answer_1": "fast", "answer_2": ["unit"]])
        guard case .received(let action) = await router.handle(data, connectionID: connection) else {
            Issue.record("All supported question fields must map back to Codex IDs"); return
        }
        #expect(action.input == .answer(["a": ["Parser"], "b": ["fast"], "c": ["unit"]]))
    }

    @Test func approvalUnknownAndMissingContextCardsHaveNoMobileControl() throws {
        for phase in [SessionPhase.approval, .unknown, .question(turnID: "t", requestID: "r", itemID: "i", questionIDs: ["q"], purpose: .unknown)] {
            let card = try SessionCard.render(snapshot(phase))
            #expect(card.form == nil && card.controlID == nil)
            #expect(!card.delivery.content.contains("lunlet_control"))
            #expect(card.delivery.content.contains("Mac"))
        }
    }

    // Refs: US-06, AC-06.05: agent Markdown stays readable, but no supplied text can open a card tag.
    @Test func suppliedTextCannotCreateMentionsOrTagsAndUnissuedFormsStayReadOnly() throws {
        let initial = snapshot(.idle(completedTurnID: "turn"))
        let value = SessionSnapshot(observation: initial.observation, project: "Lunlet", title: "Parser",
                                    publicConclusion: "Use <at id=all></at> with **bold**.\n\n```html\n<b>kept</b>\n```\nInline `a<b` stays.",
                                    localPreview: "Ask <at id=all></at> about **this** [link](x) # now")
        let card = try SessionCard.render(value)
        let (_, elements) = try parts(card)
        let quote = try #require((elements.first?["columns"] as? [[String: Any]])?.first?["elements"] as? [[String: Any]])
        #expect(quote.last?["content"] as? String
                == "Ask &#60;at id=all&#62;&#60;/at&#62; about &#42;&#42;this&#42;&#42; &#91;link&#93;(x) # now")
        let result = try #require((elements[1]["elements"] as? [[String: Any]])?[1]["content"] as? String)
        #expect(result == "Use &#60;at id=all>&#60;/at> with **bold**.\n\n```html\n<b>kept</b>\n```\nInline `a<b` stays.")
        #expect(card.form == nil && card.controlID == nil)
        #expect(!card.delivery.content.contains("lunlet_control") && !card.delivery.content.contains("\"form\""))
    }

    private func parts(_ card: RenderedSessionCard) throws -> ([String: Any], [[String: Any]]) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(card.delivery.content.utf8)) as? [String: Any])
        let elements = try #require((json["body"] as? [String: Any])?["elements"] as? [[String: Any]])
        return (json, elements)
    }

    // Refs: US-06, AC-06.01, AC-06.02; US-09, AC-09.01: a header tinted by the outcome naming the agent and the event,
    // with the project and local time below; the request as a tinted block, the reply in a bordered block; no controls.
    @Test func notificationCardsShowTheGistInAStructuredLayout() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let finished = Date(timeIntervalSince1970: 1_793_435_520) // 2026-10-31 16:32 in Shanghai
        let value = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                       phase: .idle(completedTurnID: "turn")),
                                    project: "lunlet", publicConclusion: "## Done\n\n- Parser keeps Unicode\n- Tests pass",
                                    outcome: .succeeded, lastActivityAt: finished, localPreview: "Fix the parser so it keeps Unicode")
        let card = try SessionCard.render(value, now: finished, calendar: calendar, locale: Locale(identifier: "en_GB"))
        let (json, elements) = try parts(card)
        #expect(json["schema"] as? String == "2.0")
        let header = try #require(json["header"] as? [String: Any])
        #expect(header["template"] as? String == "green")
        #expect((header["title"] as? [String: Any])?["content"] as? String == "Codex succeeded")
        #expect((header["subtitle"] as? [String: Any])?["content"] as? String == "lunlet · 16:32")
        #expect((header["icon"] as? [String: Any])?["token"] as? String == SessionCard.headerIcon && header["text_tag_list"] == nil)
        let summary = ((json["config"] as? [String: Any])?["summary"] as? [String: Any])?["content"] as? String
        #expect(summary == "Codex succeeded · lunlet: Fix the parser so it keeps Unicode")
        let body = try #require(json["body"] as? [String: Any])
        #expect(body["padding"] as? String == "12px 12px 20px 12px" && body["vertical_spacing"] as? String == "12px")
        #expect(elements.map { $0["tag"] as? String } == ["column_set", "interactive_container"])
        let request = try #require((elements[0]["columns"] as? [[String: Any]])?.first)
        #expect(request["background_style"] as? String == "green-50")
        #expect((request["elements"] as? [[String: Any]])?.map { $0["content"] as? String }
                == ["**<font color='green'>You asked</font>**", "Fix the parser so it keeps Unicode"])
        #expect(elements[1]["has_border"] as? Bool == true && elements[1]["border_color"] as? String == "green-100")
        #expect((elements[1]["elements"] as? [[String: Any]])?.map { $0["content"] as? String }
                == ["**<font color='green'>Codex</font>**", "**Done**\n\n- Parser keeps Unicode\n- Tests pass"])
        // The time moved into the header and the Mac boundary into the blocks; a Codex card without a reply box stays
        // silent about replies, while a Claude Code card says they are not available.
        for text in ["\"hr\"", "Approvals stay", "Replies from your phone", "\"form\"", "\"button\"", "\"input\"", "select_static",
                     "lunlet_control", "Mobile input is unavailable"] {
            #expect(!card.delivery.content.contains(text))
        }
        let claude = SessionSnapshot(observation: value.observation, project: "lunlet", outcome: .succeeded,
                                     lastActivityAt: Date(), provider: .claude)
        #expect(try SessionCard.render(claude).delivery.content.contains(SessionNotice.repliesUnavailableFooter))
    }

    // Refs: US-06, AC-06.01, AC-06.04: the header's tint and title follow evidence; waits keep the reader on the Mac.
    @Test(arguments: [(TaskCue.Outcome.failed, "Codex failed", "red"), (.stopped, "Codex stopped", "grey"), (.unknown, "Codex finished", "indigo")])
    func headersFollowTheEvidence(_ outcome: TaskCue.Outcome, _ title: String, _ color: String) throws {
        func header(_ json: [String: Any]) -> (String?, String?) {
            let header = json["header"] as? [String: Any]
            return ((header?["title"] as? [String: Any])?["content"] as? String, header?["template"] as? String)
        }
        let value = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                       phase: .idle(completedTurnID: "turn")), project: "Lunlet", outcome: outcome)
        let (json, elements) = try parts(try SessionCard.render(value))
        #expect(header(json) == (title, color))
        // Without a request the reply block comes first, in the tone's color; without a reply it says so.
        let block = try #require(elements.first?["elements"] as? [[String: Any]])
        #expect(block.first?["content"] as? String == "**<font color='\(color)'>Codex</font>**")
        #expect(block.last?["content"] as? String == SessionCard.escaped(SessionNotice.prepare(value).result().fallback))
        let (approval, approvalElements) = try parts(try SessionCard.render(snapshot(.approval)))
        #expect(header(approval) == ("Codex needs approval", "orange"))
        #expect((approvalElements.first?["elements"] as? [[String: Any]])?.first?["content"] as? String
                == "**<font color='orange'>Needs you</font>**")
    }

    // Refs: US-06, AC-06.02, AC-06.05: a reply larger than the card limit is cut and says the rest is on the Mac.
    @Test func longRepliesStayWithinTheCardLimit() throws {
        // Unspaced three-byte text and JSON-escaped quotes are the worst cases for the encoded size.
        let unspaced = String((0..<9_000).map { Character(UnicodeScalar(0x4E00 + $0 % 2_000)!) })
        let quoted = String(repeating: "\"quoted\"\n", count: 3_000)
        for reply in [unspaced, quoted, "```\n" + quoted] {
            let value = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                           phase: .idle(completedTurnID: "turn")), project: "Lunlet",
                                        publicConclusion: reply)
            let card = try SessionCard.render(value)
            #expect(card.delivery.content.utf8.count <= SessionCard.budget)
            let result = try resultText(card)
            #expect(result.hasSuffix(NoticeText.truncationNotice) && result.count > 2_000)
        }
        // A reply that fits is shown whole.
        let whole = String(repeating: "Updated the parser. ", count: 500)
        let value = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                                       phase: .idle(completedTurnID: "turn")), project: "Lunlet",
                                    publicConclusion: whole)
        #expect(try resultText(try SessionCard.render(value)) == whole.trimmingCharacters(in: .whitespaces))
    }

    /// The agent's reply: the text under the label of the card's bordered block.
    private func resultText(_ card: RenderedSessionCard) throws -> String {
        let block = try #require(try parts(card).1.first { $0["tag"] as? String == "interactive_container" })
        return try #require((block["elements"] as? [[String: Any]])?[1]["content"] as? String)
    }

    // Refs: US-08, AC-08.01: an issued reply form is appended after the unchanged notice, and only then are replies offered.
    @Test func anIssuedFormIsAppendedAfterTheNotice() async throws {
        let snapshot = snapshot(.idle(completedTurnID: "turn")), connection = UUID()
        let router = await router(for: snapshot.observation, connection: connection)
        let form = try #require(SessionCard.form(for: snapshot))
        let control = try #require(await router.prepare(sessionID: snapshot.observation.sessionID, form: form))
        let card = try SessionCard.render(snapshot, control: control)
        #expect(try parts(card).1.map { $0["tag"] as? String } == ["interactive_container", "form"])
        #expect(!card.delivery.content.contains("Replies from your phone"))
    }

    /// Every component of a card, including those nested in forms, column sets and columns.
    private func components(_ card: RenderedSessionCard) throws -> [[String: Any]] {
        func flatten(_ items: [[String: Any]]) -> [[String: Any]] {
            items.flatMap { [$0] + flatten(($0["elements"] as? [[String: Any]] ?? []) + ($0["columns"] as? [[String: Any]] ?? [])) }
        }
        return flatten(try parts(card).1)
    }

    // Refs: US-10, AC-10.01, AC-10.02; US-05, AC-05.09: the reply box takes one reply. After it, the box keeps the
    // sent text, greys out its input and button and states the reply's progress; a closed box says why.
    @Test func replyBoxesDisableAfterOneReplyAndStateItsProgress() throws {
        let snapshot = snapshot(.idle(completedTurnID: "turn"))
        let reply = FeishuReplyCapability(token: UUID(), sessionID: snapshot.observation.sessionID, turnID: "turn",
                                          expiresAt: Date().addingTimeInterval(600))
        func box(_ state: CardReplyState) throws -> (input: [String: Any], button: [String: Any], text: String, tag: String?) {
            let card = try SessionCard.render(snapshot, reply: reply, replyState: state)
            let all = try components(card)
            let tags = (try parts(card).0["header"] as? [String: Any])?["text_tag_list"] as? [[String: Any]]
            return (try #require(all.first { $0["tag"] as? String == "input" }),
                    try #require(all.first { $0["tag"] as? String == "button" }), card.delivery.content,
                    (tags?.first?["text"] as? [String: Any])?["content"] as? String)
        }
        let open = try box(.open)
        #expect(open.tag == nil)
        #expect(open.input["disabled"] == nil && open.button["disabled"] == nil && open.input["default_value"] == nil)
        #expect(open.input["required"] as? Bool == true)
        #expect(open.text.contains(SessionNotice.replyWindowHint) && (open.button["text"] as? [String: Any])?["content"] as? String == "Send")
        // The status block names the state in its color, and the header tag repeats it for the chat list.
        for (state, line, tag) in [
            (CardReplyState.received("Run the tests"), "**<font color='grey'>Received</font>** · sending to Codex…", "Sending"),
            (.submitted("Run the tests"), "**<font color='grey'>Sent</font>** · waiting for Codex to start", "Sent"),
            (.finished(.delivered, "Run the tests"), "**<font color='green'>Delivered</font>** · Codex is continuing on your Mac", "Replied"),
            (.finished(.notConfirmed, "Run the tests"), "**<font color='orange'>Not confirmed</font>** · Codex hasn't confirmed", "Unconfirmed"),
            (.finished(.refused(.sessionRunning), "Run the tests"), "**<font color='orange'>Not sent</font>** · The session is already working", "Not sent"),
        ] {
            let value = try box(state)
            #expect(value.tag == tag)
            #expect(value.input["disabled"] as? Bool == true && value.button["disabled"] as? Bool == true)
            // Feishu refuses an input that is both required and disabled (provider error 230099).
            #expect(value.input["required"] == nil)
            #expect(value.input["default_value"] as? String == "Run the tests")
            #expect((value.button["text"] as? [String: Any])?["content"] as? String == "Sent")
            #expect(value.text.contains(line))
        }
        let closed = try box(.closed(.replyWindowClosed))
        #expect(closed.tag == nil && closed.text.contains("**<font color='grey'>Replies closed</font>** · "))
        #expect(closed.input["disabled"] as? Bool == true && closed.button["disabled"] as? Bool == true)
        #expect(closed.input["required"] == nil)
        #expect(closed.input["default_value"] == nil && closed.text.contains(ContinuationRefusal.replyWindowClosed.explanation))
        // The token stays the button's only callback value in every state.
        #expect(closed.button["behaviors"] as? [[String: [String: String]]] == nil
                || (closed.button["behaviors"] as? [[String: Any]])?.first?["value"] as? [String: String] == reply.callbackValue)
    }
}
