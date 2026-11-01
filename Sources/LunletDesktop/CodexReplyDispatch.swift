// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.02, AC-08.03, AC-08.05; US-09, AC-09.02; US-10, AC-10.04; US-11, AC-11.03.
import LunletCodex
import LunletCore
import LunletFeishu

/// Routes a claimed Feishu follow-up to the Codex source that observes its session, which
/// rechecks the live CLI binding before `codex queue` runs. Other providers never receive input.
enum CodexReplyDispatch {
    static func make(observation: SessionObservationModel,
                     adapter: CodexQueueAdapter = CodexQueueAdapter()) -> FeishuReplyDispatch {
        { [weak observation] action, progress in
            guard case .followup(let text) = action.input, case .idle(let turn) = action.session.phase,
                  let source = await observation?.codexSource(for: action.session.sessionID) else {
                return .refused(.unverified)
            }
            let request = CodexContinuationRequest(sessionID: action.session.sessionID,
                                                   connectionID: action.session.connectionID,
                                                   completedTurnID: turn, text: text)
            return await adapter.continueSession(request, in: source, progress: progress)
        }
    }
}
