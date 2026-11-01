// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06; US-33, AC-33.01, AC-33.05.
// Refs: US-15, AC-15.02; US-03, AC-03.02, AC-03.03.
// Refs: US-02, AC-02.02, AC-02.05; US-03, AC-03.01.
// Refs: US-06, AC-06.01, AC-06.02, AC-06.03, AC-06.04, AC-06.05; US-07, AC-07.01, AC-07.04.
// Refs: US-13, AC-13.01, AC-13.04.
import Foundation

public struct SessionQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let value: String
        public let label: String
        public init(value: String, label: String) { self.value = value; self.label = label }
    }
    public enum Kind: Equatable, Sendable { case text, singleChoice([Option]), multipleChoice([Option]) }
    public let id: String
    public let prompt: String
    public let kind: Kind
    public init(id: String, prompt: String, kind: Kind) { self.id = id; self.prompt = prompt; self.kind = kind }
}

/// A verified original destination; revalidate it again before revealing.
public struct SessionNavigation: Equatable, Sendable {
    public let applicationName: String?
    public init(applicationName: String? = nil) { self.applicationName = applicationName }
}

/// Identity/liveness require proof. The local preview is the latest request; only the owner's own
/// completion notice may carry an excerpt of it (AC-06.02), never logs.
/// Derive values through the named transforms below, so no field is reset by omission.
public struct SessionSnapshot: Equatable, Sendable {
    /// Confirmed Codex activity does not prove original-client lifetime or input authority.
    public private(set) var activityConfirmed: Bool
    public private(set) var navigation: SessionNavigation?
    public var navigationAvailable: Bool { navigation != nil }
    public var navigationApplicationName: String? { navigation?.applicationName }
    public var hasConfirmedActivity: Bool {
        !isEnded && (observation.liveness == .alive || activityConfirmed)
    }
    public var isEnded: Bool { observation.isEnded }
    public var awaitsUser: Bool { observation.phase.awaitsUser }
    public private(set) var observation: ObservedSession
    public private(set) var project: String
    /// Source-reported title; nil presents the session placeholder.
    public private(set) var sourceTitle: String?
    public var title: String { sourceTitle ?? Self.placeholderTitle(for: observation.sessionID) }
    public private(set) var publicConclusion: String?
    public private(set) var limitations: [String]
    public private(set) var questions: [SessionQuestion]
    public private(set) var outcome: TaskCue.Outcome
    public private(set) var turnID: String?
    public private(set) var inputActivityID: String?
    public private(set) var inputPending: Bool
    /// Source-reported activity time; nil means recency is unavailable.
    public private(set) var lastActivityAt: Date?
    public private(set) var localPreview: String?
    /// A source-reported parent identifies a child task, not a second conversation.
    public private(set) var parentSessionID: UUID?
    /// The agent whose records produced this snapshot; it labels rows, cues and notifications.
    public private(set) var provider: SessionProvider

    public init(observation: ObservedSession, project: String, title: String? = nil,
                publicConclusion: String? = nil, limitations: [String] = [],
                questions: [SessionQuestion] = [], outcome: TaskCue.Outcome = .unknown, turnID: String? = nil,
                inputActivityID: String? = nil, inputPending: Bool = false, activityConfirmed: Bool = false,
                navigation: SessionNavigation? = nil, lastActivityAt: Date? = nil, localPreview: String? = nil,
                parentSessionID: UUID? = nil, provider: SessionProvider = .codex) {
        self.activityConfirmed = activityConfirmed; self.navigation = navigation
        self.observation = observation; self.project = project; self.sourceTitle = title
        self.publicConclusion = publicConclusion; self.limitations = limitations
        self.questions = questions; self.outcome = outcome
        self.turnID = turnID; self.inputActivityID = inputActivityID; self.inputPending = inputPending
        self.lastActivityAt = lastActivityAt
        self.localPreview = localPreview
        self.parentSessionID = parentSessionID
        self.provider = provider
    }

    public static func placeholderTitle(for sessionID: UUID) -> String { "Session " + sessionID.uuidString.prefix(8) }

    /// Lost or ended verification. Activity confirmation, navigation evidence and
    /// pending questions never survive it; summaries and identity remain.
    public func degraded(liveness: CLILiveness, phase: SessionPhase) -> Self {
        var copy = self
        copy.observation = observation.replacing(liveness: liveness, phase: phase)
        copy.activityConfirmed = false; copy.navigation = nil; copy.questions = []
        return copy
    }

    /// An ended snapshot keeps the previous same-connection summary where the exit carried none.
    public func retainingSummary(of previous: SessionSnapshot?) -> Self {
        var copy = degraded(liveness: observation.liveness, phase: observation.phase)
        guard let previous else { return copy }
        copy.publicConclusion = publicConclusion ?? previous.publicConclusion
        if limitations.isEmpty { copy.limitations = previous.limitations }
        copy.lastActivityAt = lastActivityAt ?? previous.lastActivityAt
        copy.localPreview = localPreview ?? previous.localPreview
        copy.parentSessionID = parentSessionID ?? previous.parentSessionID
        return copy
    }
}

/// What a session event tells the owner, locally and in a completion notice. The local summary and the
/// input gates (`requiresMac`, `questions`, `allowsFollowup`) keep their conservative rules; the notice
/// content adds the request excerpt and the agent's final reply (AC-06.02).
public struct SessionNotice: Equatable, Sendable {
    /// The header color of a notice: only evidence makes a turn succeeded or failed.
    /// `finished` is a normal end whose source reports no explicit success, as Codex's completion record does; it is
    /// shown in the product's color rather than the grey of a stopped or unknown state.
    public enum Tone: String, Equatable, Sendable { case succeeded, finished, failed, neutral, attention }
    /// The agent's final reply as a channel shows it, prepared on demand because it can be long.
    public struct Result: Equatable, Sendable {
        /// Cleaned Markdown, at most `SessionNotice.resultLimit` bytes; nil when no reply was captured.
        public let text: String?
        /// The reply was longer than a notice keeps; every channel ends it with the truncation notice.
        public let shortened: Bool
        /// The honest line shown instead of a missing reply.
        public let fallback: String
        /// Tells the reader that sensitive-looking text was hidden.
        public let note: String?
    }
    public static let requestLimit = 140
    public static let resultLimit = 32_768
    public static let approvalsFooter = "Approvals stay on your Mac"
    public static let repliesUnavailableFooter = "Replies from your phone aren't available yet"
    /// A reply box takes one reply, until the Mac unlocks or the control's lifetime ends (AC-05.09).
    public static let replyWindowHint = "Reply within \(Int(ContinuationGate.controlLifetime / 60)) min while locked"

    public let project: String
    public let title: String
    /// The observed agent's product name, so every notification identifies its source.
    public let agent: String
    /// The local plain-text summary of the session state, shown by the panel.
    public let summary: String
    public let requiresMac: Bool
    public let questions: [SessionQuestion]
    public let allowsFollowup: Bool
    /// The title is the generated placeholder rather than a source-reported name.
    public let titleIsPlaceholder: Bool
    /// What happened, such as "Turn finished"; the heading adds the project.
    public let headline: String
    public let tone: Tone
    /// A status symbol for channels without a colored header.
    public let symbol: String
    /// The agent and the session title, or a short form of the request when the title is a placeholder.
    public let subtitle: String
    /// The latest request on one line of at most `requestLimit` characters.
    public let request: String?
    /// The body label: Result for a finished turn, otherwise what the session needs.
    public let resultLabel: String
    /// Limitations that must stay with the result.
    public let notes: [String]
    /// The source-reported time of the event; nil when the source gave none.
    public let eventDate: Date?
    private let eventVerb: String
    private let reply: String?
    private let replyFallback: String

    public var heading: String { headline + " · " + project }

    /// The headline as a short status label for a header tag, such as "Finished".
    public var status: String {
        switch headline {
        case "Approval needed on your Mac": "Approval needed"
        case "Needs you on your Mac": "Needs you"
        case "Question waiting": "Question"
        case "Session ended": "Ended"
        case "Status unknown": "Unknown"
        default: headline.hasPrefix("Turn ") ? headline.dropFirst(5).prefix(1).uppercased() + headline.dropFirst(6) : headline
        }
    }

    /// The local time of the event in English, such as "16:52", with the date when it is not today and the
    /// locale's 12- or 24-hour clock.
    public func eventTime(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let eventDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
        let time = twelveHour ? "h:mm a" : "HH:mm"
        formatter.dateFormat = calendar.isDate(eventDate, inSameDayAs: now) ? time : "MMM d, " + time
        return formatter.string(from: eventDate)
    }

    /// The event time with its verb, such as "Finished 16:52", for text footers.
    public func timeLabel(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        eventTime(now: now, calendar: calendar, locale: locale).map { eventVerb + " " + $0 }
    }

    /// The headline as a notification title naming the agent, such as "Codex finished" or "Codex needs approval".
    public var agentHeadline: String {
        switch headline {
        case "Approval needed on your Mac": agent + " needs approval"
        case "Needs you on your Mac": agent + " needs you"
        case "Question waiting": agent + " has a question"
        case "Session ended": agent + " session ended"
        case "Status unknown": agent + " status unknown"
        case "Working": agent + " is working"
        default: headline.hasPrefix("Turn ") ? agent + " " + headline.dropFirst(5) : agent + " · " + headline
        }
    }

    /// The footer line. A card with a reply box states its window in the box, so the footer then omits replies.
    public func footer(repliesAvailable: Bool = false, now: Date = Date(), calendar: Calendar = .current,
                       locale: Locale = .current) -> String {
        ([timeLabel(now: now, calendar: calendar, locale: locale), Self.approvalsFooter]
            + (repliesAvailable ? [] : [Self.repliesUnavailableFooter])).compactMap { $0 }.joined(separator: " · ")
    }

    public func result() -> Result {
        guard let reply else { return .init(text: nil, shortened: false, fallback: replyFallback, note: nil) }
        let (redacted, hidden) = NoticeText.redact(reply)
        let cleaned = NoticeText.cleanMarkdown(redacted)
        let note = hidden ? "Some text that looked private was hidden." : nil
        guard !cleaned.isEmpty else { return .init(text: nil, shortened: false, fallback: replyFallback, note: note) }
        let kept = NoticeText.prefix(cleaned, utf8Limit: Self.resultLimit)
        return .init(text: kept, shortened: kept != cleaned || reply.utf8.count >= NoticeText.captureLimit,
                     fallback: replyFallback, note: note)
    }

    public static func prepare(_ snapshot: SessionSnapshot) -> Self {
        let observation = snapshot.observation
        let namesSafe = safe(snapshot.project, limit: 120) && safe(snapshot.title, limit: 160)
            && !snapshot.project.contains("/") && !snapshot.project.contains("\\")
        let project = namesSafe ? snapshot.project : "Project"
        let title = namesSafe ? snapshot.title : SessionSnapshot.placeholderTitle(for: observation.sessionID)
        let agent = snapshot.provider.displayName
        var requiresMac = !namesSafe || observation.liveness != .alive
        var parts: [String] = []
        var notes: [String] = []
        var ordinary = false
        var idle = false
        let headline: String, tone: Tone, symbol: String
        var label = "Result", fallback = "Result not captured — open it on your Mac."
        switch observation.phase {
        case .unknown:
            parts.append("Session state is unconfirmed."); requiresMac = true
            (headline, tone, symbol) = ("Status unknown", .neutral, "❔")
            (label, fallback) = ("Status", "Session state is unconfirmed. Check it on your Mac.")
        case .running:
            parts.append("Work is running.")
            (headline, tone, symbol) = ("Working", .neutral, "⏳")
            (label, fallback) = ("Status", "Work is still running.")
        case .approval:
            parts.append("Execution approval is required on your Mac."); requiresMac = true
            (headline, tone, symbol) = ("Approval needed on your Mac", .attention, "⚠️")
            (label, fallback) = ("Needs you", agent + " is waiting for an execution approval. Approve or decline it on your Mac.")
        case .ended:
            parts.append("The session has ended."); requiresMac = true
            (headline, tone, symbol) = ("Session ended", .neutral, "⏹️")
            (label, fallback) = ("Status", "The session has ended.")
        case .idle:
            idle = true
            switch snapshot.outcome {
            case .succeeded:
                parts.append("Turn succeeded."); (headline, tone, symbol) = ("Turn succeeded", .succeeded, "✅")
            case .failed:
                parts.append("Turn failed."); (headline, tone, symbol) = ("Turn failed", .failed, "❌")
            case .stopped:
                parts.append("Turn stopped."); (headline, tone, symbol) = ("Turn stopped", .neutral, "⏹️")
                fallback = "The turn was stopped before a final reply."
            case .unknown:
                parts.append("Turn finished; its outcome is unconfirmed.")
                (headline, tone, symbol) = ("Turn finished", .finished, "🏁")
            }
        case .question(_, _, _, _, let purpose):
            ordinary = purpose == .ordinary
            parts.append(ordinary ? "An answer is needed." : "This request needs attention on your Mac.")
            if !ordinary { requiresMac = true }
            (headline, tone, symbol) = (ordinary ? "Question waiting" : "Needs you on your Mac", .attention, "⚠️")
            (label, fallback) = ("Needs you", agent + " is waiting for an answer. Answer it on your Mac.")
        }
        if let conclusion = snapshot.publicConclusion, !conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if safe(conclusion, limit: 480) { parts.append(conclusion) }
            else { parts.append("Review the full result on your Mac."); requiresMac = true }
        }
        if !snapshot.limitations.isEmpty {
            let line: String
            if snapshot.limitations.count <= 8, snapshot.limitations.allSatisfy({ safe($0, limit: 180) }),
               snapshot.limitations.reduce(0, { $0 + $1.utf8.count }) <= 400 {
                line = "Limitations: " + snapshot.limitations.joined(separator: " ")
            } else {
                line = "Material limitations require review on your Mac."
                requiresMac = true
            }
            parts.append(line); notes.append(line)
        }
        var questions: [SessionQuestion] = []
        if ordinary, !requiresMac {
            if validQuestions(snapshot) { questions = snapshot.questions }
            else { requiresMac = true }
        }
        if !questions.isEmpty { (label, fallback) = ("Question", questions.map(\.prompt).joined(separator: "\n")) }
        if requiresMac { parts.append("Return to your Mac to continue safely.") }
        // The owner's own notice carries a request excerpt and the final reply.
        let request = snapshot.localPreview.flatMap { NoticeText.excerpt(NoticeText.redact($0).text, limit: requestLimit) }
        // A placeholder title adds nothing when the request is shown below, so the subtitle names only the agent.
        let placeholder = titleIsPlaceholder(namesSafe, snapshot)
        let subtitle = placeholder ? (request == nil ? agent + " · " + title : agent) : agent + " · " + title
        let reply = idle && snapshot.outcome != .stopped ? snapshot.publicConclusion : nil
        return Self(project: project, title: title, agent: agent, summary: parts.joined(separator: "\n"),
                    requiresMac: requiresMac, questions: questions, allowsFollowup: idle && !requiresMac,
                    titleIsPlaceholder: titleIsPlaceholder(namesSafe, snapshot), headline: headline, tone: tone,
                    symbol: symbol, subtitle: subtitle, request: request, resultLabel: label, notes: notes,
                    eventDate: snapshot.lastActivityAt, eventVerb: idle ? "Finished" : "Updated",
                    reply: reply.map { NoticeText.prefix($0, utf8Limit: NoticeText.captureLimit) }, replyFallback: fallback)
    }

    private static func titleIsPlaceholder(_ namesSafe: Bool, _ snapshot: SessionSnapshot) -> Bool {
        !namesSafe || snapshot.sourceTitle == nil
    }

    private static func validQuestions(_ snapshot: SessionSnapshot) -> Bool {
        guard case .question(_, _, _, let ids, .ordinary) = snapshot.observation.phase,
              !snapshot.questions.isEmpty, snapshot.questions.count <= 8,
              Set(ids).count == ids.count, Set(snapshot.questions.map(\.id)) == Set(ids),
              snapshot.questions.count == ids.count else { return false }
        var visibleBytes = 0
        for question in snapshot.questions {
            guard !question.id.isEmpty, question.id.utf8.count <= 256, safe(question.prompt, limit: 1_000) else { return false }
            visibleBytes += question.prompt.utf8.count
            switch question.kind {
            case .text: break
            case .singleChoice(let options), .multipleChoice(let options):
                guard !options.isEmpty, options.count <= 20, Set(options.map(\.value)).count == options.count else { return false }
                for option in options {
                    guard safe(option.label, limit: 160), safe(option.value, limit: 128) else { return false }
                    visibleBytes += option.label.utf8.count + option.value.utf8.count
                }
            }
        }
        return visibleBytes <= 4_000
    }

    private static func safe(_ text: String, limit: Int) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= limit,
              !text.contains("://"), !text.contains("```"), !text.contains("-----BEGIN"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return false }
        let pattern = #"(?i)(?:bearer\s+|sk-[a-z0-9_-]{8,}|gh[pousr]_[a-z0-9]{8,}|AKIA[0-9A-Z]{12,}|password\s*[:=]|(?:token|secret|api[_ -]?key)\s*[:=]|eyJ[A-Za-z0-9_-]{10,}\.|<analysis|<think|/(?:Users|home|private|var|tmp)/)"#
        return text.range(of: pattern, options: .regularExpression) == nil
    }
}
