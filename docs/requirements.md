# Product requirements

Lunlet helps an individual developer notice when coding work needs attention and continue it during short periods away from the computer. The Mac remains the primary work environment; mobile provides limited continuation of work already started there.

This document records agreed product behavior as user stories. It is a specification, not a claim that integrations have been proven. Evidence and outstanding feasibility work belong in [the feasibility notes](feasibility.md).

## Release scope

| Area | First release | Later or excluded |
|---|---|---|
| Platform | macOS | Linux later; other platforms not planned |
| Agent | Existing local Codex CLI sessions | Other agents later |
| CLI environment | Local Codex CLI integration independent of terminal product; Superset and iTerm are reference validation environments | tmux, SSH, Desktop and IDE integrations |
| Mobile channel | A user-owned Feishu application bot | Other channels only if Feishu cannot meet a core requirement |
| Remote actions | Answer ordinary questions; send follow-up instructions after a turn finishes | New conversations, new tasks, active-turn takeover, execution approvals, general computer control |
| Interface | Compact, notch-inspired desktop panel with an entry point on displays without a notch | A full chat client, remote desktop, team console, agent orchestration |

An **active session** is a local CLI session that is still open: running, waiting for input or approval, or idle after a turn finishes. A **finished turn** may still leave the original task unfinished. An **ended session** has exited and is no longer eligible for mobile continuation. A stored or loaded thread alone does not prove that a terminal session is active.

## Story approval and traceability

Every product capability must be specified by a user story and its acceptance criteria in this document before code is written. README text, technical notes, implementation plans, and code comments cannot authorize additional behavior.

- Story status is `Proposed`, `Confirmed`, `Deferred`, or `Rejected`. Only the product owner can confirm a new story or a material change to agreed behavior. Confirmation in conversation must be recorded here before implementation; an agent cannot approve its own proposal.
- US-01 through US-13 record the agreed first-release scope. Confirmation records product intent, not technical feasibility or completed implementation. No application code has been implemented yet.
- Review proposed or changed stories for user value, release scope, contradictions, duplication, security boundaries, dependencies, and testable outcomes before confirming them. Record unresolved issues with the proposal and stop only the affected implementation.
- For a proposed revision, retain the confirmed behavior and record the proposed changes and affected criterion IDs separately until the product owner confirms them. Do not overwrite the implementation baseline with an unconfirmed revision.
- Every code change, including experiments, tests, refactoring, and supporting infrastructure, must identify the confirmed story IDs and acceptance-criterion IDs it serves. Supporting work must explain the connection; it must not introduce unrelated behavior or invent a technical user story to bypass this rule.
- Plans and code-change descriptions must map affected code and tests to those IDs and state how the criteria will be verified. When implementation starts, maintain an `Implementation evidence` entry under each affected story linking source entry points, tests, and verification results. Evidence must be updated when behavior, code locations, or criteria change.
- Missing, unknown, unconfirmed, or contradictory requirements block the affected code change. Referencing an ID alone is insufficient: review must check that the actual behavior and verification match the cited criteria. Follow-up requirements changes must assess linked code and tests before implementation resumes.
- Keep story IDs and acceptance-criterion IDs stable. Do not renumber or reuse them when reordering or retiring requirements. Record replacements explicitly so existing code and test references remain understandable.

## User stories

All stories below are required for the first release. Their order follows the user journey, not an implementation schedule. Acceptance criteria use stable IDs in the form `AC-<story number>.<criterion number>`.

### US-01: Connect Feishu with minimal setup

Status: Confirmed.

**As a developer, I want to connect my own Feishu bot by scanning and authorizing, so that I can enable mobile continuation without configuring developer infrastructure manually.**

Acceptance criteria:

- **AC-01.01**: **Given** Feishu is not connected, **When** I choose Connect Feishu, **Then** Lunlet presents the official application registration and authorization flow.
- **AC-01.02**: **Given** I scan and authorize successfully, **When** setup completes, **Then** Lunlet obtains the user-owned application's credentials, stores them in macOS secure storage, prepares the required configuration, and reports connection status.
- **AC-01.03**: **Given** a normal setup, **When** I follow the flow, **Then** I do not need to create an application in the developer console, select individual permissions, or copy secrets manually.
- **AC-01.04**: **Given** authorization is denied, expires, or is blocked by organization permissions, **When** setup cannot finish, **Then** Lunlet explains the failure and offers a recoverable next step without claiming success.
- **AC-01.05**: **Given** Feishu setup succeeds, **When** mobile access is configured, **Then** Lunlet binds it to the verified owner identity for that application and requests only necessary messaging permissions, without unrelated calendar or document access.
- **AC-01.06**: **Given** connection and privacy information is presented, **When** I review the access boundary, **Then** Lunlet explains its owner access controls and applicable organization restrictions without claiming that a user-owned bot is immune to Feishu administration.

### US-02: Automatically see all active sessions

Status: Confirmed.

**As a developer, I want Lunlet to discover and monitor all active Codex CLI sessions, so that I do not need to register each session or switch between terminals to check progress.**

Acceptance criteria:

- **AC-02.01**: **Given** active local Codex CLI sessions, **When** Lunlet observes them, **Then** each appears with its project or directory, session identity or title, agent, state, and latest activity through Codex-level integration without terminal-product-specific monitoring adapters.
- **AC-02.02**: **Given** two sessions in the same project, **When** either changes state, **Then** the update is attributed to the correct session.
- **AC-02.03**: **Given** the panel is collapsed, **When** sessions change state, **Then** it presents a compact agent status and the number of sessions waiting for the developer, with completion or failure indications that do not steal focus.
- **AC-02.04**: **Given** a session starts or is restored by me on the Mac, **When** it becomes observable, **Then** Lunlet includes it automatically without a per-session enable step.
- **AC-02.05**: **Given** session state cannot be confirmed, **When** Lunlet displays it, **Then** it shows uncertainty rather than inventing running, completed, or failed status or unsupported progress percentages; remote input is unavailable until identity and state are confirmed.
- **AC-02.06**: **Given** monitoring is active, **When** there is no new activity requiring attention, **Then** Lunlet remains quiet without stealing focus, repeatedly notifying, or unnecessarily expanding the panel; monitoring overhead is measured during validation.

### US-03: Inspect a session and return to its terminal

Status: Confirmed.

**As a developer, I want to inspect a session's recent activity and return to its terminal, so that I can understand what needs attention and continue working with minimal window switching.**

Acceptance criteria:

- **AC-03.01**: **Given** monitored sessions, **When** I expand the panel and select one, **Then** I can identify it and inspect its confirmed current activity, recent public output or summary, and latest result.
- **AC-03.02**: **Given** a supported, identifiable terminal destination, **When** I choose the return action, **Then** Lunlet opens the corresponding session destination rather than an unrelated foreground terminal.
- **AC-03.03**: **Given** the destination cannot be located reliably, **When** I request the return action, **Then** Lunlet explains that the destination is unavailable without guessing; session observation and mobile continuation remain available when their own eligibility checks pass.
- **AC-03.04**: **Given** a display without a hardware notch, **When** I use Lunlet, **Then** I still have an accessible entry point to the session panel.

### US-04: Understand account limits and session usage

Status: Confirmed.

**As a developer, I want to see trustworthy limits and usage with their source and freshness, so that I can judge whether my work can continue.**

Acceptance criteria:

- **AC-04.01**: **Given** the source provides account quota windows, **When** I inspect limits, **Then** Lunlet shows the supported remaining allowance, reset time, source, and last update time separately from session state.
- **AC-04.02**: **Given** session token or cost information is available, **When** it is displayed, **Then** account quota, session usage, actual billing, and token-based cost estimates are clearly distinguished.
- **AC-04.03**: **Given** a value is unavailable or a refresh fails, **When** the panel renders, **Then** an unknown or stale value is identified as such and is not replaced with zero.
- **AC-04.04**: **Given** enabling usage access requires local login credentials, **When** I first enable it, **Then** Lunlet explains the source, purpose, and request destination without exposing or forwarding credentials through Feishu.
- **AC-04.05**: **Given** limits are being monitored, **When** Lunlet schedules refreshes, **Then** it avoids unnecessary frequent polling and repeated notifications; refresh frequency and overhead are recorded during validation.

### US-05: Enable Away Mode for all active sessions

Status: Confirmed.

**As a developer, I want one Away Mode switch to enable mobile continuation and keep the Mac reachable, so that I can step away without configuring individual sessions or power settings.**

Acceptance criteria:

- **AC-05.01**: **Given** Away Mode is off and Feishu is connected, **When** I turn it on, **Then** Feishu notifications and supported mobile continuation cover all active sessions automatically, including sessions discovered while the mode remains enabled.
- **AC-05.02**: **Given** active sessions are already waiting for input or idle after a finished turn, **When** I enable Away Mode, **Then** their current state and eligible continuation controls become available in Feishu without waiting for another session event; pending execution approvals remain Mac-only.
- **AC-05.03**: **Given** Feishu setup is incomplete or its connection is unavailable, **When** I try to enable mobile continuation, **Then** Lunlet explains what is unavailable without reporting remote access as ready; local session monitoring remains available.
- **AC-05.04**: **Given** Away Mode is on, **When** work is running, waiting, or idle after a turn, **Then** Lunlet prevents idle system sleep while allowing screen locking and display sleep.
- **AC-05.05**: **Given** Away Mode is on, **When** I turn it off or quit Lunlet, **Then** Lunlet releases its sleep-prevention request and restores the system's normal power behavior.
- **AC-05.06**: **Given** I am using the first release, **When** Away Mode changes, **Then** the change is explicit; automatic presence detection is not required.

### US-06: Receive concise, actionable notifications

Status: Confirmed.

**As a developer, I want short Feishu summaries when work finishes, fails, or needs me, so that I can decide what to do next without reading the full conversation.**

Acceptance criteria:

- **AC-06.01**: **Given** Away Mode is on, **When** a monitored session finishes a turn, fails, asks an ordinary question, or needs execution approval, **Then** its notification identifies the project and session and explains the event with necessary context.
- **AC-06.02**: **Given** a result notification, **When** I read it, **Then** I see a short summary rather than the entire final response or conversation, with material failures and limitations preserved.
- **AC-06.03**: **Given** the first-release summary path, **When** a notification is prepared, **Then** Lunlet prioritizes existing public Codex conclusions and confirmed state without requiring another model account, API key, or paid summarization service.
- **AC-06.04**: **Given** a question cannot be presented safely within a concise message, **When** Lunlet notifies me, **Then** it asks me to return to the Mac rather than omitting context needed for a reliable answer.
- **AC-06.05**: **Given** a notification or question card is prepared, **When** Lunlet sends it to Feishu, **Then** the payload contains only necessary public summary and question context, excluding credentials, authentication files, complete source files, hidden reasoning, and full conversation history.

### US-07: Answer an ordinary question from mobile

Status: Confirmed.

**As a developer, I want to answer the current question from its Feishu card, so that the original session can continue while I am away.**

Acceptance criteria:

- **AC-07.01**: **Given** a verified ordinary question is pending, **When** I open its card, **Then** I see sufficient question context and the applicable options or text input.
- **AC-07.02**: **Given** I submit an answer, **When** Lunlet forwards it, **Then** it targets that exact session, turn, and pending request and retains the original context.
- **AC-07.03**: **Given** the question was already answered, cancelled, expired, or superseded, **When** I submit its old card, **Then** no answer is forwarded and I receive an explanation.
- **AC-07.04**: **Given** the request may authorize execution or its purpose cannot be established, **When** Lunlet evaluates it, **Then** mobile answering is unavailable even if the protocol calls it a user-input request.

### US-08: Send a follow-up to the same session

Status: Confirmed.

**As a developer, I want to add a follow-up instruction after a turn finishes, so that I can move the unfinished task forward in the same conversation.**

Acceptance criteria:

- **AC-08.01**: **Given** the original CLI session is still open and ready for follow-up, **When** I submit an instruction from its Feishu card, **Then** the next turn uses that session's identity and existing context.
- **AC-08.02**: **Given** the instruction is accepted, **When** Codex processes it, **Then** its existing sandbox and approval policy remain in force.
- **AC-08.03**: **Given** the session has ended, is executing a new turn, or is waiting for execution approval, **When** I submit a stale follow-up card, **Then** Lunlet does not start a new session, take over the running turn, or treat the instruction as approval.
- **AC-08.04**: **Given** the next turn produces a result, **When** it is available, **Then** its notification and receipt remain associated with the original session.

### US-09: Keep execution approvals on the Mac

Status: Confirmed.

**As a developer, I want execution approvals to remain on my computer, so that limited mobile continuation does not broaden the agent's authority.**

Acceptance criteria:

- **AC-09.01**: **Given** Codex needs execution approval, **When** Feishu notifies me, **Then** it asks me to approve on the Mac and provides no mobile approval control.
- **AC-09.02**: **Given** I send text such as "yes" or "continue", **When** an execution approval is pending, **Then** Lunlet does not translate that text into authorization.
- **AC-09.03**: **Given** a follow-up requires an action outside the session's permissions, **When** Codex requests approval, **Then** it waits for the original desktop approval process; Lunlet does not weaken the sandbox or enable automatic approval.

### US-10: Receive reliable action receipts

Status: Confirmed.

**As a developer, I want each mobile action to have a clear outcome and execute at most once, so that I can trust the result despite retries or repeated taps.**

Acceptance criteria:

- **AC-10.01**: **Given** an action is received, **When** its status changes, **Then** the receipt distinguishes received, submitted to Codex, processing confirmed, and failure; transport success alone is not task success.
- **AC-10.02**: **Given** a duplicate callback, repeated tap, or out-of-order operation, **When** it arrives, **Then** it cannot cause duplicate execution or answer a later request accidentally.
- **AC-10.03**: **Given** submission times out and the outcome is unknown, **When** Lunlet reports the result, **Then** it states that uncertainty and does not blindly resubmit.
- **AC-10.04**: **Given** a mobile action arrives, **When** Lunlet validates it, **Then** input is forwarded only if the owner and application, local installation, session, turn or request, and validity period all match the current eligible state; unauthorized, mismatched, or expired actions are rejected without guessing a foreground destination.

### US-11: Handle unavailable and ended sessions

Status: Confirmed.

**As a developer, I want unavailable or ended sessions to stop accepting mobile actions, so that delayed messages cannot restart work or reach the wrong request.**

Acceptance criteria:

- **AC-11.01**: **Given** the Mac sleeps, loses network access, or otherwise becomes unreachable, including after lid closure, **When** mobile continuation is unavailable, **Then** the connection state is made clear when observable; Lunlet does not promise execution while offline or assume that closing the lid preserves reachability.
- **AC-11.02**: **Given** mobile instructions were sent during an interruption, **When** the connection recovers, **Then** Lunlet does not automatically execute them and rechecks current session and request state before accepting a fresh submission.
- **AC-11.03**: **Given** a CLI session actually ends, **When** Lunlet detects that exit, **Then** its mobile continuation stops and its old cards become invalid; Lunlet does not restart Codex or restore history automatically.
- **AC-11.04**: **Given** I restore the session on the Mac, **When** it becomes active again, **Then** Lunlet rediscovers it and includes it if Away Mode is still on, without reviving old cards.
- **AC-11.05**: **Given** Lunlet restarts, **When** monitoring recovers, **Then** it revalidates session and pending-request identities before accepting remote input and does not replay previously received actions.
- **AC-11.06**: **Given** a terminal window closes or a thread remains loaded, **When** Lunlet determines eligibility, **Then** it uses verified session lifecycle evidence rather than window presence or loaded-thread status alone.

### US-12: Stop mobile access and disconnect

Status: Confirmed.

**As a developer, I want to stop mobile continuation and disconnect Feishu, so that I remain in control of remote access to my local sessions.**

Acceptance criteria:

- **AC-12.01**: **Given** Away Mode is on, **When** I turn it off, **Then** new mobile input is rejected, Feishu notifications stop, and all previously issued mobile controls become invalid while local session monitoring remains available.
- **AC-12.02**: **Given** Feishu is connected, **When** I disable remote input or disconnect the integration, **Then** affected cards can no longer submit actions.
- **AC-12.03**: **Given** mobile access is enabled again after Away Mode was turned off, remote input was disabled, or Feishu was disconnected, **When** continuation becomes available, **Then** only fresh controls targeting revalidated current sessions and requests can submit actions; earlier controls remain invalid.
- **AC-12.04**: **Given** Lunlet is running, **When** I quit it, **Then** its remote-control connections and sleep-prevention request are released, without leaving unexplained background control.

### US-13: Notice task starts and completions locally

Status: Confirmed.

**As a developer, I want brief task-start and task-completion cues in the notch-inspired panel while I am using my Mac, so that I can notice activity without switching terminals.**

A task event here refers to a Codex turn, not each tool call or shell command. Finishing a turn does not mean that the whole task is complete or that the session has ended.

Acceptance criteria:

- **AC-13.01**: **Given** Lunlet is running and the display is on and unlocked, **When** a monitored session starts or finishes a confirmed turn, **Then** the panel briefly shows the project or session identity and the start or completion state, including success or failure only when confirmed, independently of Away Mode and Feishu connection status.
- **AC-13.02**: **Given** a transient cue is visible, **When** its presentation timeout expires, **Then** the panel returns to its prior presentation without taking keyboard focus or activating another application; a panel I opened manually remains open.
- **AC-13.03**: **Given** the display is asleep or the Mac is locked, **When** task events arrive, **Then** Lunlet updates session state without showing these transient cues or waking the display; returning to the Mac shows current state without replaying cues for those events.
- **AC-13.04**: **Given** a session is newly discovered or monitoring reconnects, **When** existing state or a duplicate event is received, **Then** Lunlet updates the session without presenting an old transition as a new task start or completion.
- **AC-13.05**: **Given** several sessions change state close together, **When** cues are presented, **Then** Lunlet combines or updates them to avoid repeated expansion while keeping each event associated with the correct session and preserving its outcome.
- **AC-13.06**: **Given** a display without a hardware notch, **When** an eligible task event occurs, **Then** the equivalent desktop panel provides the same transient cue.

## Release acceptance

The first release is ready when the stories above pass in the declared macOS and Codex CLI versions. Record the reference terminal environments used for verification without making terminal brands a capability allowlist. Verification must cover at least two concurrent sessions, two sessions in the same project, continued context over multiple turns, local task cues with and without Away Mode, display sleep and lock behavior, lock-screen mobile interaction, approval isolation, duplicate and stale actions, enabling Away Mode with already-pending work, disabling and re-enabling mobile access, unavailable Feishu setup or connectivity, disconnection, session exit and restore, and quitting Lunlet.

Record reproducible steps, observed results, supported versions, and failure boundaries in [the feasibility notes](feasibility.md). The developer must be able to start work on the Mac, step away, receive useful summaries, answer an ordinary question or send a follow-up to the correct existing session, and understand the outcome without maintaining a separate agent platform.
