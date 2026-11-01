// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.02, AC-02.05; US-03, AC-03.01.
// Refs: US-06, AC-06.01, AC-06.02, AC-06.03, AC-06.04, AC-06.05; US-07, AC-07.01, AC-07.04.
// Refs: US-33, AC-33.01, AC-33.05.
import Foundation
import Testing
import LunletCore

struct SessionNoticeTests {
    private func snapshot(phase: SessionPhase = .idle(completedTurnID: "turn"), conclusion: String? = nil,
                          limitations: [String] = [], questions: [SessionQuestion] = [],
                          outcome: TaskCue.Outcome = .unknown, liveness: CLILiveness = .alive,
                          title: String? = "Fix the build", preview: String? = nil, at date: Date? = nil) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: liveness, phase: phase),
                        project: "Lunlet", title: title, publicConclusion: conclusion,
                        limitations: limitations, questions: questions, outcome: outcome,
                        lastActivityAt: date, localPreview: preview)
    }

    // Refs: US-06, AC-06.02; US-13, AC-13.08: the header states only what the records prove.
    @Test(arguments: [
        (TaskCue.Outcome.succeeded, "Turn succeeded", SessionNotice.Tone.succeeded, "✅"),
        (.failed, "Turn failed", .failed, "❌"),
        (.stopped, "Turn stopped", .neutral, "⏹️"),
        (.unknown, "Turn finished", .finished, "🏁"),
    ]) func finishedTurnsNameTheirEvidencedOutcome(_ outcome: TaskCue.Outcome, _ headline: String,
                                                    _ tone: SessionNotice.Tone, _ symbol: String) {
        let notice = SessionNotice.prepare(snapshot(outcome: outcome))
        #expect(notice.headline == headline && notice.tone == tone && notice.symbol == symbol)
        #expect(notice.heading == headline + " · Lunlet" && notice.resultLabel == "Result")
        #expect(notice.status == String(headline.dropFirst("Turn ".count)).capitalized)
        #expect(notice.agentHeadline == "Codex " + headline.dropFirst("Turn ".count))
    }

    // Refs: US-06, AC-06.01, AC-06.04; US-09, AC-09.01: waits send the reader back to the Mac.
    @Test func approvalsAndQuestionsNeedAttentionOnTheMac() {
        let approval = SessionNotice.prepare(snapshot(phase: .approval))
        #expect(approval.tone == .attention && approval.headline == "Approval needed on your Mac")
        #expect(approval.status == "Approval needed" && approval.agentHeadline == "Codex needs approval")
        #expect(approval.result().text == nil && approval.result().fallback.contains("on your Mac"))
        #expect(approval.requiresMac && !approval.allowsFollowup)
        let phase = SessionPhase.question(turnID: "turn", requestID: "request", itemID: "item",
                                          questionIDs: ["question"], purpose: .unknown)
        let question = SessionNotice.prepare(snapshot(phase: phase, conclusion: "Earlier reply"))
        #expect(question.tone == .attention && question.resultLabel == "Needs you")
        #expect(question.result().text == nil && question.result().fallback.contains("Answer it on your Mac"))
    }

    // Refs: US-06, AC-06.02, AC-06.03: the request and the agent's whole final reply are carried.
    @Test func requestAndFullResultAreCarriedWithFailureAndLimitations() {
        let reply = "## Summary\n\n" + String(repeating: "Updated the parser and its tests. ", count: 200)
        let notice = SessionNotice.prepare(snapshot(conclusion: reply, limitations: ["Tests were not run."], outcome: .failed,
                                                    preview: "Fix the parser so it keeps Unicode"))
        #expect(notice.request == "Fix the parser so it keeps Unicode")
        let result = notice.result()
        #expect(result.text == NoticeText.cleanMarkdown(reply) && !result.shortened && result.note == nil)
        #expect(notice.tone == .failed && notice.notes == ["Limitations: Tests were not run."])
        // The local summary keeps its conservative bounded form.
        #expect(notice.summary.contains("failed") && notice.summary.contains("Tests were not run."))
        #expect(notice.summary.utf8.count <= 1_200 && notice.requiresMac && !notice.allowsFollowup)
    }

    // Refs: US-06, AC-06.02: a missing reply is said honestly instead of inventing one.
    @Test func missingResultsUseAnHonestLine() {
        let finished = SessionNotice.prepare(snapshot())
        #expect(finished.request == nil && finished.result().text == nil)
        #expect(finished.result().fallback == "Result not captured — open it on your Mac.")
        let stopped = SessionNotice.prepare(snapshot(conclusion: "Partial work", outcome: .stopped))
        #expect(stopped.result().text == nil && stopped.result().fallback == "The turn was stopped before a final reply.")
        let blank = SessionNotice.prepare(snapshot(conclusion: " \n\u{200B}\t "))
        #expect(blank.result().text == nil)
    }

    // Refs: US-06, AC-06.02: requests become one bounded line; long replies are marked as shortened.
    @Test func requestsAndResultsAreCleanedAndBounded() throws {
        let preview = "Make\tthe   card\u{202E} readable " + String(repeating: "and polished ", count: 20)
        let notice = SessionNotice.prepare(snapshot(conclusion: "Line one\r\n\r\n\r\n\r\nLine two  \u{0007}",
                                                    preview: preview))
        let request = try #require(notice.request)
        #expect(request.count <= SessionNotice.requestLimit && request.hasSuffix("…") && !request.contains("\u{202E}"))
        #expect(request.hasPrefix("Make the card readable and polished") && !request.hasSuffix(" …"))
        #expect(notice.result().text == "Line one\n\nLine two")
        let long = SessionNotice.prepare(snapshot(conclusion: String(repeating: "word ", count: 7_000)))
        let result = long.result()
        #expect(result.shortened && (result.text?.utf8.count ?? 0) <= SessionNotice.resultLimit)
    }

    // Refs: US-06, AC-06.05: secret-looking text and hidden reasoning never reach a channel.
    @Test(arguments: ["Bearer synthetic-secret-value-123", "api_key=synthetic-secret", "sk-synthetic-secret-value-1234",
                      "<analysis>private synthetic reasoning</analysis>",
                      "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----"])
    func sensitiveTextIsHiddenFromTheResult(_ content: String) {
        let notice = SessionNotice.prepare(snapshot(conclusion: "Done. " + content + " Next."))
        let result = notice.result()
        #expect(result.note != nil)
        #expect(!(result.text ?? "").contains("synthetic-secret") && !(result.text ?? "").contains("private synthetic"))
        #expect(!(result.text ?? "").contains("\nsynthetic\n") && (result.text ?? "").hasPrefix("Done."))
        // The local summary still falls back to the Mac for unsafe text.
        #expect(!notice.summary.contains(content) && notice.requiresMac && !notice.allowsFollowup)
    }

    // Refs: US-06, AC-06.02, AC-06.05: ordinary Markdown, links and code stay; home folders are shortened.
    @Test func ordinaryMarkdownStaysReadable() {
        let reply = "Fixed `/Users/synthetic-owner/project/Parser.swift`.\n\n```swift\nlet value = a < b\n```\nSee https://example.invalid/docs."
        let result = SessionNotice.prepare(snapshot(conclusion: reply)).result()
        #expect(result.text == "Fixed `~/project/Parser.swift`.\n\n```swift\nlet value = a < b\n```\nSee https://example.invalid/docs.")
        #expect(result.note == nil)
    }

    // Refs: US-06, AC-06.02: headings become bold lines and local file links keep only their label, outside code.
    @Test func headingsAndLocalLinksReadLikeAMessage() {
        let reply = "## Summary\nEdited [Parser.swift](/Users/synthetic-owner/project/Parser.swift:12) and "
            + "[docs](https://example.invalid/docs).\n### Next ###\n```md\n## kept\n[a](b)\n```\nInline `[x](y)` stays."
        let text = NoticeText.cleanMarkdown(reply)
        #expect(text == "**Summary**\nEdited `Parser.swift` and [docs](https://example.invalid/docs).\n**Next**\n"
                + "```md\n## kept\n[a](b)\n```\nInline `[x](y)` stays.")
    }

    // Refs: US-06, AC-06.01; US-03, AC-03.01: a placeholder title is not repeated beside the request it stands for.
    @Test func subtitleNamesTheAgentAndTheSessionOrItsRequest() {
        #expect(SessionNotice.prepare(snapshot(preview: "Ignored for a named session")).subtitle == "Codex · Fix the build")
        let unnamed = snapshot(title: nil, preview: "Investigate why the release build fails on the second launch after an update")
        let notice = SessionNotice.prepare(unnamed)
        // The request is shown in its own block, so the subtitle names only the agent.
        #expect(notice.titleIsPlaceholder && notice.subtitle == "Codex" && notice.request?.hasPrefix("Investigate why") == true)
        let bare = SessionNotice.prepare(snapshot(title: nil))
        #expect(bare.title.hasPrefix("Session ") && bare.subtitle == "Codex · " + bare.title)
    }

    // Refs: US-06, AC-06.01: the footer gives the local time and never offers replies without a control.
    @Test func footerShowsLocalTimeAndTheMacBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let finished = Date(timeIntervalSince1970: 1_793_435_520) // 2026-10-31 16:32 in Shanghai
        let notice = SessionNotice.prepare(snapshot(at: finished))
        let footer = notice.footer(now: finished.addingTimeInterval(60), calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(footer == "Finished 16:32 · Approvals stay on your Mac · Replies from your phone aren't available yet")
        #expect(notice.timeLabel(now: finished, calendar: calendar, locale: Locale(identifier: "en_US")) == "Finished 4:32 PM")
        #expect(notice.eventTime(now: finished, calendar: calendar, locale: Locale(identifier: "en_GB")) == "16:32")
        #expect(notice.timeLabel(now: finished.addingTimeInterval(86_400), calendar: calendar, locale: Locale(identifier: "en_GB"))
                == "Finished Oct 31, 16:32")
        #expect(notice.footer(repliesAvailable: true, now: finished, calendar: calendar, locale: Locale(identifier: "en_GB"))
                == "Finished 16:32 · Approvals stay on your Mac")
        #expect(SessionNotice.replyWindowHint == "Reply within 10 min while locked")
        #expect(SessionNotice.prepare(snapshot()).footer() == "Approvals stay on your Mac · Replies from your phone aren't available yet")
    }

    @Test func shortPublicConclusionsRemainUsefulWithoutInventingSuccess() {
        let notice = SessionNotice.prepare(snapshot(conclusion: "Updated the parser to preserve Unicode."))
        #expect(notice.summary.contains("Updated the parser to preserve Unicode."))
        // A normal finish without an explicit success flag is shown in the product color, never as success.
        #expect(!notice.summary.contains("succeeded") && notice.tone == .finished)
        #expect(notice.project == "Lunlet" && notice.title == "Fix the build")
        #expect(notice.allowsFollowup)
        let stopped = SessionNotice.prepare(snapshot(outcome: .stopped, liveness: .unverified))
        #expect(stopped.summary.contains("stopped") && !stopped.summary.contains("succeeded"))
        #expect(stopped.requiresMac && !stopped.allowsFollowup)
    }

    @Test func ordinaryQuestionsRequireCompleteMatchingContext() {
        let question = SessionQuestion(id: "question", prompt: "Which build should run?", kind: .singleChoice([
            .init(value: "fast", label: "Fast"), .init(value: "full", label: "Full")]))
        let phase = SessionPhase.question(turnID: "turn", requestID: "request", itemID: "item",
                                          questionIDs: ["question"], purpose: .ordinary)
        let notice = SessionNotice.prepare(snapshot(phase: phase, questions: [question]))
        #expect(notice.questions == [question] && notice.resultLabel == "Question")
        #expect(notice.result().fallback == "Which build should run?")
        #expect(!notice.requiresMac && !notice.allowsFollowup)
        let missing = SessionNotice.prepare(snapshot(phase: phase))
        #expect(missing.questions.isEmpty && missing.requiresMac)
    }

    @Test(arguments: [QuestionPurpose.authorization, .unknown])
    func requestNamesAndTextCannotAuthorizeMobileQuestions(_ purpose: QuestionPurpose) {
        let phase = SessionPhase.question(turnID: "turn", requestID: "request", itemID: "item",
                                          questionIDs: ["question"], purpose: purpose)
        let notice = SessionNotice.prepare(snapshot(phase: phase,
                                                    questions: [.init(id: "question", prompt: "Continue?", kind: .text)]))
        #expect(notice.questions.isEmpty && notice.requiresMac && !notice.allowsFollowup)
    }

    @Test func endedUnverifiedAndOversizedQuestionContextsHaveNoInput() {
        for liveness in [CLILiveness.ended, .unverified] {
            let notice = SessionNotice.prepare(snapshot(liveness: liveness))
            #expect(notice.questions.isEmpty && !notice.allowsFollowup && notice.requiresMac)
        }
        let phase = SessionPhase.question(turnID: "turn", requestID: "request", itemID: "item",
                                          questionIDs: ["question"], purpose: .ordinary)
        let notice = SessionNotice.prepare(snapshot(phase: phase, questions: [
            .init(id: "question", prompt: String(repeating: "🙂", count: 1_001), kind: .text)]))
        #expect(notice.questions.isEmpty && notice.requiresMac)
    }

    // Refs: US-33, AC-33.01, AC-33.05.
    @Test func providerIdentitySurvivesTransformsAndNamesTheAgent() {
        let codex = snapshot()
        #expect(codex.provider == .codex && SessionNotice.prepare(codex).agent == "Codex")
        let claude = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified,
                                                        phase: .idle(completedTurnID: "turn")), project: "Lunlet",
                                     publicConclusion: "Synthetic reply", activityConfirmed: true,
                                     localPreview: "Synthetic request", provider: .claude)
        #expect(claude.degraded(liveness: .ended, phase: .ended).provider == .claude)
        #expect(claude.retainingSummary(of: codex).provider == .claude)
        let notice = SessionNotice.prepare(claude)
        // An unverified original client always sends Claude back to the Mac without reply controls.
        #expect(notice.agent == "Claude Code" && notice.requiresMac && !notice.allowsFollowup)
        #expect(notice.subtitle == "Claude Code" && notice.result().text == "Synthetic reply")
        #expect(!notice.summary.contains("Synthetic request"))
    }
}
