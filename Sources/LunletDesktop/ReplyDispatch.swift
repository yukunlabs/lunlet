// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.02, AC-08.03, AC-08.05; US-09, AC-09.02; US-10, AC-10.04; US-11, AC-11.03;
// US-38, AC-38.02, AC-38.03.
import LunletClaude
import LunletCodex
import LunletCore
import LunletFeishu

/// Routes a claimed follow-up to the source that observes its session, which rechecks the live CLI binding
/// before anything runs: `codex queue` for Codex, the Stop hook helper for Claude Code. No other path takes input.
enum ReplyDispatch {
    static func make(observation: SessionObservationModel, codex: CodexQueueAdapter = CodexQueueAdapter(),
                     claude: ClaudeHookAdapter = ClaudeHookAdapter()) -> FeishuReplyDispatch {
        { [weak observation] action, progress in
            guard case .followup(let text) = action.input, case .idle(let turn) = action.session.phase,
                  let owner = await observation?.source(for: action.session.sessionID) else {
                return .refused(.unverified)
            }
            switch owner.provider {
            case .codex:
                guard let source = owner.source as? any CodexSessionObserving else { return .refused(.unverified) }
                let request = CodexContinuationRequest(sessionID: action.session.sessionID,
                                                       connectionID: action.session.connectionID,
                                                       completedTurnID: turn, text: text)
                return await codex.continueSession(request, in: source, progress: progress)
            case .claude:
                guard let source = owner.source as? any ClaudeSessionObserving else { return .refused(.unverified) }
                let request = ClaudeContinuationRequest(sessionID: action.session.sessionID,
                                                        connectionID: action.session.connectionID,
                                                        completedTurnID: turn, text: text)
                return await claude.continueSession(request, in: source, progress: progress)
            }
        }
    }
}
