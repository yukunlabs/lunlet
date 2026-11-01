# Product requirements

Lunlet helps an individual developer notice when coding work needs attention and continue it during short periods away from the computer. The Mac remains the primary work environment; mobile provides limited continuation of work already started there.

This document records agreed product behavior as user stories. It is a specification, not a claim that integrations have been proven. Evidence and outstanding feasibility work belong in [the feasibility notes](feasibility.md).

## Release scope

| Area | First release | Later or excluded |
|---|---|---|
| Platform | macOS | Linux later; other platforms not planned |
| Agent | Existing local Codex sessions: CLI, Codex App, editor clients, execution and child sessions with readable local records; local Claude Code sessions for observation, usage and notifications (US-33) | Claude phone replies, Cursor and other agents later; remote-only or unpersisted sessions unavailable |
| Codex environment | Local observation independent of client or terminal product; original CLI continuation is separately gated | SSH and remote-host discovery; control of Desktop and IDE clients |
| Mobile channel | User-owned Feishu/Lark, Slack, or Telegram bots; one selected channel | Other messaging services |
| Remote actions | Answer ordinary questions; send follow-up instructions after a turn finishes | New conversations, new tasks, active-turn takeover, execution approvals, general computer control |
| Interface | Compact, notch-inspired desktop panel with an entry point on displays without a notch | A full chat client, remote desktop, team console, agent orchestration |

Observation and accounting include all observable local Codex client types. Original-app navigation requires its own verified destination. Notification delivery requires a verified event and selected owner-bound channel. Mobile answering and follow-up remain restricted to eligible original CLI sessions and their separately validated input path; observing Codex App, editor, execution or child sessions does not promise controlling them. Feishu card input is the first-release continuation target. Slack and Telegram pairing messages establish private notification recipients, not a general chat-to-Codex route.

**Active sessions** in the panel are observed sessions the user has not cleared; a finished turn or process exit does not move them into History automatically. A **live CLI connection** may remain open and eligible for a follow-up even while its conversation is in History; liveness and list placement are separate facts. A **finished turn** may still leave the original task unfinished. An **ended session** has exited and is no longer eligible for mobile continuation. A stored or loaded thread alone does not prove that a terminal session is active.

## Epics and user journey

These Epics group existing confirmed stories by user outcome. Stories retain their stable IDs even though they are now ordered by journey rather than creation date. A story has one primary Epic; dependencies do not create duplicate ownership.

| Epic | User outcome | Stories |
|---|---|---|
| EPIC-01 | Stay aware of current Codex work | US-02, US-03, US-13, US-15, US-23, US-33 |
| EPIC-02 | Understand allowance and recorded usage | US-04, US-18, US-32 |
| EPIC-03 | Connect one private channel and receive useful updates | US-01, US-20, US-22, US-05, US-06 |
| EPIC-04 | Continue the correct existing CLI conversation safely | US-07, US-08, US-09, US-10, US-11, US-36 |
| EPIC-05 | Personalize a focused and durable macOS interface | US-31, US-16, US-17, US-21, US-19, US-26 |
| EPIC-06 | Keep control of access and application reliability | US-12, US-14, US-24, US-25 |
| EPIC-07 | Publish and support a trustworthy product | US-28, US-27, US-29, US-30, US-34, US-35 |

The everyday journey is:

1. Launch Lunlet and begin existing work on the Mac. EPIC-01 automatically discovers observable sessions; EPIC-02 shows account quota and local recorded usage. Neither depends on connecting a messenger.
2. Inspect work locally. Start and input cues identify sessions; sessions enter History only when the user clears them. Clear hides Active entries locally, new verified work restores them, and an identifiable original destination may be reopened. History has no separate clear action.
3. Optionally choose and connect one messaging channel. EPIC-03 distinguishes authorization, private recipient binding, delivery, callback reception and session-input readiness. A saved credential does not imply a usable return path.
4. Lock the Mac. Newly verified completions are delivered automatically under AC-05.06; startup/recovery snapshots are not replayed as new completions. Unlocking, disconnecting or quitting stops this notification path. No main-panel Away Mode switch is required.
5. For the full continuation target, answer the exact pending ordinary-question card or submit a follow-up from its completion card. EPIC-04 requires verified original-CLI identity and lifecycle, EPIC-03 owner/callback readiness and EPIC-06 revocation safeguards. It preserves context and permissions, provides an accurate receipt, and never turns arbitrary chat or an execution approval into input.
6. On exit, interruption, restart, channel changes or return to the Mac, revalidate capabilities and invalidate stale controls. Recover the affected stage without clearing unrelated local work; Quit releases owned operations and power assertions.

EPIC-05 enhances this journey without making unsupported providers operational. EPIC-07 applies before public publication; optional support never gates the coding workflow. EPIC-06 safeguards apply across every other Epic.

## Delivery and unresolved decisions

Approval, release scope, implementation and acceptance are separate facts. The Implementation evidence under each story records actual delivery; feasibility notes carry reproducible results. This grouping does not mark any partial story complete.

| Story | Current runtime delivery | Remaining gate |
|---|---|---|
| US-01 | Scan-based setup of a new or existing app, owner-bound delivery and callback reception, verified live | Feishu card review in the phone app |
| US-02 | Wired local discovery and compact status | Question/approval classification and original App/VS Code device acceptance |
| US-03 | Wired local inspection and destination gates | Physical notch/hover/display and original-host navigation acceptance |
| US-04 | Wired account/local usage, estimates and Settings explanation | Source-specific account and physical presentation acceptance |
| US-05 | Automatic locked completion delivery; Codex completion cards carry a reply box during the unlock-ended reply window (AC-05.09), verified live | The Settings switch (AC-05.08) and initial-state controls (AC-05.02) |
| US-06 | Completed-turn notices with the request excerpt and the agent's final reply on all three channels; the Feishu card and the Telegram and Slack notices verified live | Feishu card review in the phone app; question, approval and failure classifications |
| US-07 | Card-only callback ingress for completion-card follow-ups, verified live on a scan-created app; answering questions unavailable | Question provenance and an original-CLI answer path |
| US-08 | Gated `codex queue` follow-up path from the completion card's reply box: live-binding recheck, delivery confirmed from the session record, session-named receipts; verified live | Live refusal paths and broader device acceptance |
| US-09 | Follow-ups refused while a turn runs or waits for approval; queued input keeps the session's policy, verified live | Live execution-approval challenge through the mobile path |
| US-10 | Received, submitted, confirmed, unconfirmed, failed and refused receipts with at-most-once dispatch; in-place card updates verified live | Timeout and reconnect journey |
| US-11 | Exited, reused-PID, restored and reconnected sessions refuse before queueing (synthetic) | Live callback/input recovery and network-loss acceptance |
| US-12 | Wired Quit/cleanup; isolated input revocation | Full continuation activation/re-enable and live stale-control invalidation |
| US-13 | Wired start/input/completion cues and suppression | Owner visual and multi-display/full-screen acceptance |
| US-14 | Wired bounded macOS unified logging and the bounded local error file | On-device opt-in diagnostics checks |
| US-15 | Wired Active/History, source-recency ordering and Clear | Original-device list lifecycle acceptance |
| US-16 | Wired native RGB/hue and shared warning palette | Owner visual acceptance |
| US-17 | Wired Vine/Lantern and validated declarative skins | Physical style and imported-skin acceptance |
| US-18 | Wired persisted one-to-seven-day charts | Automated/native checks exist; final owner evaluation |
| US-19 | Codex and Claude Code selectable; one provider shown directly, several with a segmented Overview of totals and parallel provider tabs | On-device tab acceptance; Cursor remains later scope |
| US-20 | Three-channel notification selection and private binding; Telegram and Slack pairing and locked delivery verified live | None beyond release signing |
| US-36 | Slack and Telegram notices take one reply that continues the same Codex session, with the notice rewritten in place; both verified live | None beyond release signing |
| US-21 | Wired exclusive notch/menu modes and full artwork | Physical lock/wake and display-transition acceptance |
| US-22 | Wired factual readiness in Settings and the attached card for every channel, and explicit credential recovery | None beyond release signing |
| US-23 | Wired identifiable Active/History without search/filter, with source-reported relative ages | Final large-list owner evaluation |
| US-24 | Wired chart keyboard access, panel Command-R/Command-comma, symbol-and-label states and chart descriptors | Physical VoiceOver and full connection-card focus order |
| US-25 | Wired bounded readers and independent successful freshness | Real-discovery, uncached full-app CPU/memory/disk/wakeup/latency acceptance |
| US-26 | Wired validated non-secret preferences and recovery | Signed-app upgrade/credential continuity is a separate release gate |
| US-27 | Source published; CI and packaging prepared, including the unsigned preview package mode | Clean-machine validation and the first unsigned preview release; Developer ID signing and notarization deferred by owner decision |
| US-28 | Product page published on GitHub Pages with the repository link; download and support links stay hidden until their destinations exist | Browser, responsive and keyboard acceptance of the published page |
| US-29 | 0BSD license with SPDX headers, provenance inventory, packaged notices, trademark statement and About details | Confirmation of the icon's generation terms and the privacy-claim review before a binary release |
| US-30 | Optional link omitted until an approved URL exists | Owner support destination; optional and not a coding-workflow gate |
| US-34 | Contribution guide, issue forms and PR template in place; branch protection and private vulnerability reporting are enabled at publication | First external PR acceptance |
| US-35 | Sparkle 2.10.1 wired for configured release builds: footer notice, About controls, embedded signed framework; synthetic evidence only | An EdDSA update key, a published appcast and a real update installed on a clean Mac; Developer ID signing deferred by owner decision |
| US-31 | Wired six-category native Settings | Final physical usability acceptance |
| US-32 | Range forecast from full-resolution readings, even-pace line and stale, too-early and exhausted states | Live predicted-versus-observed accuracy over a real week and packaged-app review |
| US-33 | Phase A: registry and transcript observation, recorded usage, locked completion notifications; status-line plan limits, account email and plan from Claude Code's local profile, tokens-first usage; synthetic evidence plus live status-line readings | Owner-assisted live Claude session, usage, locked delivery, Pro/Max reading and footer checks |

## Story approval and traceability

Every product capability must be specified by a user story and its acceptance criteria in this document before code is written. README text, technical notes, implementation plans, and code comments cannot authorize additional behavior.

- Story status is `Proposed`, `Confirmed`, `Deferred`, or `Rejected`. Only the product owner can confirm a new story or a material change to agreed behavior. Confirmation in conversation must be recorded here before implementation; an agent cannot approve its own proposal.
- US-01 through US-15 establish the original core journey; AC-14.04 and AC-14.05 remain explicitly deferred. US-16 through US-31 are activated for local work. Confirmation authorizes the recorded intent; release membership follows the scope above, not the word Confirmed. Claude Code observation in US-33 is first-release scope; Claude phone replies, Cursor and other agents are later work. US-27 through US-29 gate public publication, and US-30 is optional. Implementation evidence and on-device acceptance are separate from approval. No activation bypasses unresolved decision or feasibility gates.
- Review proposed or changed stories for user value, release scope, contradictions, duplication, security boundaries, dependencies, and testable outcomes before confirming them. Record unresolved issues with the proposal and stop only the affected implementation.
- For a proposed revision, retain the confirmed behavior and record the proposed changes and affected criterion IDs separately until the product owner confirms them. Do not overwrite the implementation baseline with an unconfirmed revision.
- Every code change, including experiments, tests, refactoring, and supporting infrastructure, must identify the confirmed story IDs and acceptance-criterion IDs it serves. Supporting work must explain the connection; it must not introduce unrelated behavior or invent a technical user story to bypass this rule.
- Plans, source headers, and test references must map implementation and verification to those IDs. When implementation starts, maintain an `Implementation evidence` entry under each affected story linking source entry points, tests, and verification results. Evidence must be updated when behavior, code locations, or criteria change.
- Missing, unknown, unconfirmed, or contradictory requirements block the affected code change. Referencing an ID alone is insufficient: review must check that the actual behavior and verification match the cited criteria. Follow-up requirements changes must assess linked code and tests before implementation resumes.
- Each story belongs to exactly one outcome-based Epic; shared dependencies link to the owning story rather than duplicating its behavior. Epic grouping does not authorize new functionality. Keep story IDs and acceptance-criterion IDs stable. Do not renumber or reuse them when reordering or retiring requirements. Record replacements explicitly so existing code and test references remain understandable.
- Product page linkage: a story the product page presents declares `Product page: #section`. The site build refuses a page section that presents a story that is not `Confirmed`, and refuses to build while a confirmed story's declared section does not present it; the page's facts (agents, messengers, skins, macOS target) are read from the sources, and its pictures carry a manifest of the sources they were rendered from (`scripts/check_site_assets.py`). A story therefore reaches the page in the same change that confirms it, or the build says what is missing.
- Feedback intake: record new owner feedback as TODOs by default rather than immediately investigating or implementing it. Bugs are priority 1; new features are priority 2. Priority orders the backlog, not permission to start. Resume the selected work when the owner explicitly requests execution; keep first-release publication gates separate from feature scheduling.

## Proposed Codex setup constraint

Status: Proposed, not accepted for installation or product behavior. A native, terminal-independent path to the original CLI is preferred, and `codex queue` from the completion card now provides it for follow-ups, so this setup would be considered only for capabilities that path cannot offer, and then only as an explicit, removable opt-in in Settings whose exact mechanism, undo path and affected sessions require confirmation first. This authorizes investigation, not installing a launcher or hooks, changing global configuration or silently revising the confirmed baseline.

Such a launch-path integration would require a one-time Codex integration setup. Subsequent locally started or manually restored CLI sessions would be included automatically, regardless of terminal product. Sessions opened before that setup would require one manual restore on the Mac, retaining their existing conversation, before mobile continuation could become available. Lunlet would not restart or restore them automatically.

This changes the compatibility boundary of US-02 / AC-02.01 and AC-02.04, US-08 / AC-08.01, and US-11 / AC-11.04. It is not authorized by an implementation detail: product-owner confirmation is required before implementing or installing this launch-path integration. The inspected Codex version offers no equivalent lifecycle and request-ownership interface for arbitrary, already-running uninstrumented CLIs.

## Open items

Work that is not finished or not yet accepted. Confirmed behavior not listed here is implemented and covered by tests; the acceptance gates that remain open are listed per story above and in [feasibility](feasibility.md).

- Claude Code "No resets right now" state (US-33 / AC-33.09): show it with wording and placement aligned to Codex if Claude exposes a reliable equivalent; keep unavailable or ambiguous data unknown. Not started.
- Live acceptance pending: Feishu cards in the phone app (US-06); the execution-approval challenge through the mobile path (US-09); original VS Code and Codex App acceptance of integrated-terminal discovery (US-02); physical lock, wake and display-transition recovery of the notch entry (US-03, US-21); the two-cord lantern skin on the device (US-17).
- TODO (bug, priority 1, mitigated): Quit stalled twice on 2026-11-01 (01:15 and 01:24) while a Slack reply listener was active; the system log holds each quit's `shutdown started` without stages or completion. Both stalls ran a build that predates the fix that resumes a Socket Mode receive on cancellation, and every later quit completed within 100 ms, so that receive is the probable cause but is unproven. Since then each shutdown stage waits at most two seconds and logs `uncertain`/`timeout` with its number, and the eight-second watchdog remains. Acceptance needs one owner reproduction: Slack selected, a Codex turn finishing while the Mac is locked, then unlock and quit within ten minutes; a clean quit with all nine stages logged closes this item (US-12 / AC-12.04, US-14 / AC-14.01; evidence in [feasibility](feasibility.md#messaging-channels)).
- Release gates: an EdDSA update key, a published appcast and a real update installed on a clean Mac (US-35), which also confirms that the saved bot connection survives the update without a prompt (US-26, AC-27.05); Developer ID signing and notarization are deferred by the owner's decision of 2026-11-01 to ship an unsigned preview first (AC-27.05); branding, artwork rights and privacy-claim review before a binary release (US-29); an approved support destination (US-30).
- Release decisions still open: the download and support links on the published product page; supported architectures, version and tag rules, release checks and draft-release review; an owner-generated EdDSA update key, the appcast's published URL and release notes per version. No certificate purchase, release, hosted site or paid service is authorized by this list.
- Open question: whether a card's reply window should end only when the Mac unlocks, rather than after ten minutes while it stays locked (AC-05.09).
- Question and approval classification (US-02 / AC-02.03, AC-02.05): pending ordinary questions and execution approvals are not yet classified from session records; no such state is inferred until they are. Not started.
- Phone-reply switch and initial-state cards (US-05 / AC-05.08, AC-05.02): the Settings switch that allows phone replies and the cards for sessions already waiting or idle when delivery begins are not built; replies currently follow the locked-Mac window and card lifetime alone. Not started.
- Answering a session's question from the phone (US-07 / AC-07.01 through AC-07.05, US-09 / AC-09.01): question cards, question provenance, the original-CLI answer path and the approval notice that points back to the Mac are not built; the completion-card follow-up (US-08) is the only live input path. Not started.

## EPIC-01: Stay aware of current Codex work

Outcome: Notice what is happening, inspect the correct conversation, and return to work without managing a second chat archive.

### US-02: Automatically see all active sessions

Status: Confirmed.

Product page: #hero.

**As a developer, I want Lunlet to discover and monitor all observable local Codex sessions, so that I do not need to register each session or switch between terminals to check progress.**

Acceptance criteria:

- **AC-02.01**: **Given** active local Codex sessions from CLI, Codex App, editor clients, execution tasks or child agents, **When** Lunlet observes them, **Then** each appears with its project or directory, session identity or title, agent, state, and latest activity through Codex-level integration without terminal-product-specific monitoring adapters. Child tasks that explicitly name a parent session remain observed and counted under that parent rather than listed as separate conversations.
- **AC-02.02**: **Given** two sessions in the same project, **When** either changes state, **Then** the update is attributed to the correct session.
- **AC-02.03**: **Given** the panel is collapsed, **When** sessions change state, **Then** it presents a compact agent status and the number of sessions waiting for the developer, with completion or failure indications that do not steal focus. Unknown coverage stays in hover help and accessibility descriptions rather than adding a permanent question-mark badge.
- **AC-02.04**: **Given** a session starts or is restored by me on the Mac, **When** it becomes observable, **Then** Lunlet includes it automatically without a per-session enable step.
- **AC-02.05**: **Given** session state cannot be confirmed, **When** Lunlet displays it, **Then** it shows uncertainty rather than inventing running, completed, or failed status or unsupported progress percentages; remote input is unavailable until identity and state are confirmed.
- **AC-02.06**: **Given** monitoring is active, **When** there is no new activity requiring attention, **Then** Lunlet remains quiet without stealing focus, repeatedly notifying, or unnecessarily expanding the panel; monitoring overhead is measured during validation.
- **AC-02.07**: **Given** local Codex work, **When** I start Lunlet, **Then** session monitoring starts automatically without installing hooks, requesting hook trust, changing my Codex launch command or rewriting unrelated Codex configuration; observed activity alone never grants remote input.

- **AC-02.08**: **Given** local Codex processes holding valid session records, **When** Lunlet discovers sessions, **Then** client labels, noninteractive launch modes, Desktop originators, structured child-agent sources, and unknown or future source labels do not exclude read-only observation. Each verified session UUID appears once. Stored records alone never prove current activity; ambiguous ownership remains unverified, and observation never grants remote input or original-client navigation.

Implementation: [reader](../Sources/LunletCodex/CodexSessionReader.swift), [process reader](../Sources/LunletCodex/CodexProcessReader.swift), [monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [Shared accounting roots](../Sources/LunletCodex/CodexAccountingCatalog.swift), [usage reader](../Sources/LunletCodex/LocalUsageHistory.swift), [session list model](../Sources/LunletDesktop/SessionListModel.swift), [native views](../Sources/LunletDesktop/SessionPanel.swift), [presentation tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [desktop stream owner](../Sources/LunletDesktop/SessionObservationModel.swift), [Reader tests](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [monitor tests](../Tests/LunletCodexTests/CodexSessionMonitorTests.swift), [desktop integration tests](../Tests/LunletDesktopTests/SessionObservationModelTests.swift), [Both compact entries](../Sources/LunletDesktop/MenuBarController.swift), [Native entry tests](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [process reader](../Tests/LunletCodexTests/CodexProcessReaderTests.swift).

### US-03: Inspect a session and return to its terminal

Status: Confirmed.

**As a developer, I want to inspect a session's recent activity and return to its terminal, so that I can understand what needs attention and continue working with minimal window switching.**

Acceptance criteria:

- **AC-03.01**: **Given** monitored sessions, **When** I expand the panel and select one, **Then** I can identify it and inspect its confirmed current activity, recent public output or summary, and latest result.
- **AC-03.02**: **Given** a supported, identifiable terminal destination, **When** I double-click its session row, **Then** Lunlet reveals the original application and corresponding existing session destination, without a separate return button or a fallback to the default Terminal application.
- **AC-03.03**: **Given** the destination cannot be located reliably, **When** I request the return action, **Then** Lunlet explains that the destination is unavailable without guessing; session observation and mobile continuation remain available when their own eligibility checks pass.
- **AC-03.04**: **Given** a display without a hardware notch, **When** I use Lunlet, **Then** I still have an accessible entry point to the session panel.
- **AC-03.05**: **Given** I open the desktop panel, **When** it expands, **Then** it is centered on the physical notch at the display's top edge, or below the menu bar on a display without a notch, rather than attached to the menu-bar icon; it remains within the screen area.
- **AC-03.06**: **Given** I opened the panel manually, **When** I close it, press Escape, or move focus to another application, **Then** the panel dismisses while Lunlet remains available from its selected notch or menu-bar entry; opening it again preserves current application state.

Implementation: [Session labels](../Sources/LunletDesktop/SessionOrdering.swift), [Superset bindings](../Sources/LunletCodex/SupersetSessionBindingReader.swift), [monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [device-adaptive vectors](../Sources/LunletDesktop/VineGeometry.swift), [native entry and coordinated animation](../Sources/LunletDesktop/LettermarkView.swift), [focused regressions](../Tests/LunletDesktopTests/VineEntryTests.swift), [shared palette](../Sources/LunletDesktop/AllowancePalette.swift), [application](../Sources/LunletApp/LunletApp.swift), [notch entry](../Sources/LunletDesktop/NotchEntryController.swift), [compact native panel](../Sources/LunletDesktop/CompanionPanel.swift), [attached surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [silhouette tests](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [panel controller](../Sources/LunletDesktop/CompanionPanelController.swift), [Geometry tests](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [native interaction tests](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [entry lifecycle tests](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [optional destination reader](../Sources/LunletCodex/CodexDestinationReader.swift), [explicit host opener](../Sources/LunletDesktop/SessionDestinationOpener.swift), [monitor regressions](../Tests/LunletCodexTests/CodexSessionMonitorTests.swift), [list regressions](../Tests/LunletDesktopTests/SessionListModelTests.swift), [binding tests](../Tests/LunletCodexTests/SupersetSessionBindingReaderTests.swift).

Design note: a small blue-purple lettering mark rests close to the left of the unchanged hardware notch, without a black backing; the expanded surface uses native translucent frosted material, restrained branding and compact system typography.

- **AC-03.07**: **Given** an unlocked display with a hardware notch and notch presentation selected, **When** Lunlet is running, **Then** a compact, connected lun / let lettering entry flanks the actual notch with a slightly thicker, gently spiraling vine along its lower edge, using display geometry without enlarging or covering the hardware notch. Letter strokes grow into sparse shoots; both words react together to hover and new task cues. Only one application entry is shown: the menu-bar fallback appears only when the notch-side entry is unavailable. Temporary lock, sleep, or unsettled display state hides the surface without selecting menu-bar mode; an available notched display recovers after the transition.
- **AC-03.08**: **Given** the compact entry, **When** I hover briefly, **Then** a non-activating session preview expands beneath the notch; the preview remains open while the pointer is inside either the entry or the expanded panel, regardless of event ordering between those regions. Leaving both regions dismisses it after a short grace period; returning during that delay or retraction keeps it expanded. Clicking the entry or interacting with the preview keeps it open until explicitly dismissed or focus moves to another application. Every click inside the open panel's outline, including empty glass between and around its modules, stays with the panel and never reaches the application beneath.
- **AC-03.09**: **Given** the session panel, **When** I inspect it, **Then** the single Codex page shows weekly remaining allowance and active sessions together without a separate Overview or duplicate CLI badge, while detailed usage opens from the allowance summary, settings contains application preferences, and connection setup is available from a compact footer entry. Global Refresh and a Settings gear sit at the upper right; Quit is available without scrolling in Settings, not on the overview. Escape and outside-click dismissal close the panel without a redundant Close Panel button. Unavailable capabilities remain explicit.

Design note: the default panel shows three complete session rows when the display allows, ending cleanly after the third; further rows scroll. Account, reset, credit and usage information stays above them.

- **AC-03.10**: **Given** display changes, sleep, locking, or quitting, **When** the desktop surface updates, **Then** owned entry windows and animations follow the available display and are hidden or removed appropriately. Reduce Motion disables decorative motion, and Reduce Transparency uses an opaque readable surface.
- **AC-03.11**: **Given** a hardware notch, **When** the panel opens or closes, **Then** the resting silhouette matches the current display's system-reported notch exclusion area without fixed outward padding or an idle frosted rectangle; that same silhouette expands around the notch for cues and details. Activity cues expand horizontally without opening the full overview; details expand from the enclosing silhouette rather than dropping a separate card below it. Lettering remains synchronized. Reopening during retraction cancels the pending close. Reduce Motion uses the same attached geometry without the transition. Displays without a notch retain a simple panel.

Design note: a Superset organization without a database holds no binding, and that absence is rechecked before navigation is offered; symbolic links, unreadable databases, duplicate bindings and oversized discovery fail closed.

### US-13: Notice task starts and completions locally

Status: Confirmed.

Product page: #island.

**As a developer, I want brief task-start and task-completion cues in the notch-inspired panel while I am using my Mac, so that I can notice activity without switching terminals.**

A task event here refers to a Codex turn, not each tool call or shell command. Finishing a turn does not mean that the whole task is complete or that the session has ended.

Acceptance criteria:

- **AC-13.01**: **Given** Lunlet is running and the display is on and unlocked, **When** a monitored session starts or finishes a confirmed turn, **Then** the panel briefly shows the project or session identity and the start or completion state, including success or failure only when confirmed, independently of Away Mode and Feishu connection status.
- **AC-13.02**: **Given** a transient cue is visible, **When** its presentation timeout expires, **Then** the panel returns to its prior presentation without taking keyboard focus or activating another application; a panel I opened manually remains open.
- **AC-13.03**: **Given** the display is asleep or the Mac is locked, **When** task events arrive, **Then** Lunlet updates session state without showing these transient cues or waking the display; returning to the Mac shows current state without replaying cues for those events.
- **AC-13.04**: **Given** a session is newly discovered or monitoring reconnects, **When** existing state or a duplicate event is received, **Then** Lunlet updates the session without presenting an old transition as a new task start or completion.
- **AC-13.05**: **Given** several sessions change state close together, **When** cues are presented, **Then** the newest event immediately replaces the current cue and shows the correct session with evidence-backed state; an accumulated count does not replace session content.
- **AC-13.06**: **Given** a display without a hardware notch, **When** an eligible task event occurs, **Then** the equivalent desktop panel provides the same transient cue.
- **AC-13.07**: **Given** a notch-side entry and an eligible task cue, **When** the cue appears, **Then** concise identity and status briefly expand on both sides of the notch and retract automatically, including after new input within the same turn; the lettering can react without taking focus. Concurrent events remain attributed and accessible in the session panel.
- **AC-13.08**: **Given** an eligible start or finish cue, **When** it appears, **Then** it reads at a glance: a high-contrast island continuous with the notch extends below it, shows a bold status (Started, Completed, Stopped, Failed or Finished) with its symbol, the project, and the bounded local prompt preview, and stays about five seconds; it slides in and out and appears without motion when Reduce Motion is on. Desktop panels without a notch use the same content.
- **AC-13.09**: **Given** a task cue was shown, **When** I open the panel by hover, click or keyboard while it shows or within 15 seconds after it hides, **Then** the panel shows that cue's agent tab with the cue's conversation selected, in Active or History wherever it now is; with cues from several conversations the newest wins, and an opening without a recent cue keeps the page last shown.

Implementation: [cue presentation core](../Sources/LunletCore/CuePresentation.swift), [cue behavior tests](../Tests/LunletCoreTests/CuePresentationTests.swift), [session model](../Sources/LunletDesktop/SessionListModel.swift), [non-activating native overlay](../Sources/LunletDesktop/TransientCuePanel.swift), [Desktop model tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [Measured cue text](../Sources/LunletDesktop/TaskCueText.swift), [geometry regressions](../Tests/LunletDesktopTests/TaskCueTextTests.swift), [OS state reads](../Sources/LunletDesktop/DisplayState.swift), [cue surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [surface](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [placement tests](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [panel check](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift).

For AC-13.09, the [session model tests](../Tests/LunletDesktopTests/SessionListModelTests.swift) check that a recent cue opens the correct provider and conversation once, while a later opening keeps the prior selection.

### US-15: Organize the visible session list

Status: Confirmed.

**As a developer, I want to clear conversations from Lunlet's active list without deleting them, so that I can keep the panel focused and return to those conversations when needed.**

Acceptance criteria:

- **AC-15.01**: **Given** displayed Active sessions, **When** I clear the list, **Then** Lunlet moves them into its local history view without deleting Codex conversations, ending sessions, altering remote permissions, or stopping observation.
- **AC-15.02**: **Given** a session in local history, **When** new input or a running/waiting activity is verified, **Then** it reappears in Active, including additional input during the same turn. A finished turn or ended session does not move into History automatically. Duplicate observations, metadata-only changes, and recovery without new input/turn identity do not undo clearing.
- **AC-15.03**: **Given** cleared or ended sessions, **When** I open history, **Then** I can inspect the available bounded session summary and explicitly restore ongoing work that I cleared; cleared completed sessions remain in History until new activity appears. Ended sessions remain ineligible for remote continuation. History is local presentation of observed snapshots, not a claim to import Codex's full conversation archive.
- **AC-15.04**: **Given** monitoring is unverified, **When** history or active sessions render, **Then** their uncertainty remains visible; clearing does not turn unknown state into verified state or erase ended-connection safeguards.

- **AC-15.05**: **Given** I cleared conversations into local history, **When** I explicitly refresh the overview, **Then** Lunlet rechecks the session source and restores confirmed ongoing/waiting work to Active. Completed, ended, unavailable, or ambiguously bound conversations remain in History; background recovery alone does not undo clearing.

- **AC-15.06**: **Given** local History entries, **When** I view them, **Then** entries with known observed activity are ordered most recent first, with stable session identity for ties and no fabricated recency for unavailable activity. History has no separate clear action; neither its ordering nor Active Clear deletes Codex records or changes usage accounting.

Design note: History reviews recent results and returns to original conversations, ordered by recent activity. There is no History-clear action; Clear applies only to Active and never deletes Codex conversations, releases allowance or removes recorded usage. No retention count, expiry rule or automatic deletion exists.

Design note: Active retains observed sessions; a finished turn or ended session is not archived automatically. Clear moves sessions into History, and new input or activity restores them to Active; an explicit refresh restores confirmed ongoing sessions (AC-15.05). Rows prefer a short on-device preview of the latest user message and fall back to the session identifier; previews never enter logs, and only the owner's own completion notice carries an excerpt (AC-06.02). Sessions without identifiable content, a navigation destination and confirmed activity are not shown yet but remain observed; displayed sessions are retained during temporary monitoring interruptions. Child tasks whose source metadata names a parent session remain monitored and counted but are not shown as independent conversations and produce no cues; sessions with unknown relationships are never merged by project name. Injected AGENTS.md instructions are not treated as user input or previews.

Implementation: [list model](../Sources/LunletDesktop/SessionListModel.swift), [active/history views](../Sources/LunletDesktop/SessionPanel.swift), [lifecycle tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [Reader/monitor regressions](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [ordering/lifecycle tests](../Tests/LunletDesktopTests/SessionOrderingTests.swift).

Design note: Codex's marked runtime-context records, such as environment context, are not user input: they never restore cleared sessions, set input pending or emit Started cues, and a user message wrapped entirely in one matching tag pair is treated the same way.

### US-33: See Claude Code sessions alongside Codex

Status: Confirmed. First-release phase A: local session observation, recorded usage, locked completion notifications, provider selection and Overview. Plan percentages and reset times come from a reversible Claude Code status-line connection that Lunlet adds automatically while Claude Code is selected; Settings › Agents explains it and can disconnect it for good, and the card's Add status line button reconnects. The card uses remaining allowance, with the weekly estimate on hover and in VoiceOver; the account line shows the email and plan Claude Code caches locally (AC-33.11), and model-specific limits remain unknown. Claude phone replies are later scope. Depends on EPIC-02 for usage presentation, EPIC-03 for notification delivery and US-19 for provider selection and Overview.

Product page: #glance.

**As a developer who uses both Codex and Claude Code, I want Lunlet to observe my local Claude Code sessions alongside Codex, so that I can follow both agents and their recorded usage in one panel and be notified when either finishes while I am away.**

Acceptance criteria:

- **AC-33.01**: **Given** running local Claude Code sessions, **When** Lunlet observes them, **Then** each appears with its project or directory, session identity or title, the Claude agent label, state and latest activity, bound through Claude's per-process session record to a same-user live process with a matching start time and an exact session UUID and transcript, without hooks, settings changes or terminal-specific adapters.
- **AC-33.02**: **Given** two Claude sessions in one directory, or one session resumed in two processes, **When** either changes state, **Then** updates are attributed to the exact session; a session with more than one owning process stays ambiguous and observation-only.
- **AC-33.03**: **Given** recorded turn completion or a recorded wait for permission or input on the Mac, **When** Lunlet presents the session, **Then** it shows finished or waiting state from that evidence; unknown record types, versions or stale process records show unknown state rather than invented status.
- **AC-33.04**: **Given** recorded Claude usage, **When** I inspect usage, **Then** tokens are counted once per message across main and subagent transcripts, labeled as recorded usage on this Mac with API list-price cost estimates and a lower-bound note; Claude plan limits are shown as unknown until they are connected under AC-33.08, and any window without a reading stays unknown.
- **AC-33.05**: **Given** saved owner authorization and a confirmed locked Mac, **When** a verified Claude turn completes after the discovery baseline, **Then** the existing notification path delivers a bounded completion summary identifying Claude and the session, without replaying earlier work; Claude cards offer no reply controls.
- **AC-33.06**: **Given** Claude subagent transcripts, **When** they are observed, **Then** their usage counts under the parent session, and they are not listed as separate conversations and produce no separate cues.
- **AC-33.07**: **Given** Claude's local records, **When** Lunlet reads them, **Then** it reads only allowlisted metadata and usage fields, the bounded local preview permitted for Codex sessions and, for the completion notice (AC-06.02), the bounded text blocks of the reply that ends a turn; it keeps no thinking, tool use or tool results, never reads prompt history, tool-result or memory files, credentials, peer keys or environment values, and never connects to Claude's sockets.
- **AC-33.08**: **Given** Claude Code is a selected agent and Lunlet's status line is not connected, **When** Lunlet starts or Claude Code becomes selected, **Then** Lunlet connects its status line automatically unless I disconnected it before or Claude Code's existing status line is not a command or was changed outside Lunlet; the card says "Status line added" with Undo for that panel visit, there is no separate switch: turning Claude Code off in Settings › Agents restores the previous configuration exactly and turning it on connects again, the agent switch's help explains that a custom status line hides most of Claude Code's footer keyboard hints, and Settings › Agents shows a note only for an unusual state. The card's Undo restores the previous configuration and keeps it off across launches until its Add status line button. Lunlet keeps and chains any existing status line. The command keeps only the five-hour and seven-day `used_percentage` and `resets_at` values in a Lunlet-owned file, discards all other session data, reads no credentials, and prints a compact line such as "5h 23% · 7d 41% · resets 1h23m".
- **AC-33.09**: **Given** Claude rate-limit readings, **When** I view the Claude page, **Then** the five-hour session and weekly windows are shown separately as percent left (100% minus the reported percent used), in the same terms as the Codex allowance, with reset times and the reading's age; a missing window, an account without these limits or no reading shows unknown; the weekly window uses the provider-independent forecast semantics of AC-32.05 through AC-32.08; Claude limits are never combined with Codex allowances. Each window's meter uses the same meter and palette gradient as the Codex allowance, colored by what remains (100% minus percent used), so the low-allowance colors of AC-04.10 apply to both agents. The two windows are stacked, each a compact line (its label, reset time and percent left) over a full-width meter, so the card keeps the Codex card's height and switching tabs never shifts the page; every meter is the same 6-point height; the card's chart button and hover open Claude's weekly trend in remaining terms with the AC-32.06 estimate and Codex's wording above daily usage on this Mac, as Codex's does. Estimates name no verdict such as "On track". The reading's age uses the Codex card's wording, such as "Updated 3m ago".
- **AC-33.10**: **Given** recorded Claude usage, **When** it is shown on the Claude page, **Then** tokens lead, as for Codex, with input, output, cache-write and cache-read tokens listed separately on the card and in row and chart help, so a total dominated by cache reads can be read apart; the API-price estimate follows (rows) or is in the help (card). Every Tokens/Cost switch, on the Overview and in both agents' usage charts, reads Tokens then Cost and opens on Tokens, because a subscriber watches usage before its API-price equivalent.
- **AC-33.11**: **Given** Claude Code signed in on this Mac, **When** I view the Claude card, **Then** its account line matches the Codex card's: the account email and plan (such as Max 20x) as Claude Code caches them in its own configuration file, then the reading's age or the connection state; Lunlet reads only those two fields of that file's `oauthAccount`, never a credential, keeps them in memory, logs neither and sends them nowhere; an unknown or unrecognized value reads as unknown, never a guess. Both provider cards are titled Limits.

Implementation: [registry reader](../Sources/LunletClaude/ClaudeSessionRegistry.swift), [process check](../Sources/LunletClaude/ClaudeProcessReader.swift), [transcript locator](../Sources/LunletClaude/ClaudeProjects.swift), [transcript reader](../Sources/LunletClaude/ClaudeTranscriptReader.swift), [monitor](../Sources/LunletClaude/ClaudeSessionMonitor.swift), [usage reader](../Sources/LunletClaude/ClaudeLocalUsageReader.swift), [price table](../Sources/LunletClaude/ClaudePricing.swift), [Claude page](../Sources/LunletDesktop/ProviderSummaries.swift), [provider](../Sources/LunletCore/SessionObserving.swift), [Feishu](../Sources/LunletFeishu/SessionCard.swift), [locked notification owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [registry and process](../Tests/LunletClaudeTests/ClaudeSessionRegistryTests.swift), [transcript](../Tests/LunletClaudeTests/ClaudeTranscriptReaderTests.swift), [monitor](../Tests/LunletClaudeTests/ClaudeSessionMonitorTests.swift), [usage](../Tests/LunletClaudeTests/ClaudeLocalUsageReaderTests.swift), [multi-source desktop owner](../Tests/LunletDesktopTests/SessionObservationModelTests.swift), [provider pages](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [notifications](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [card](../Tests/LunletFeishuTests/SessionCardTests.swift), [notice](../Tests/LunletCoreTests/SessionNoticeTests.swift), [Claude Code plan limits section](../Sources/LunletDesktop/ClaudePlanLimitsSettings.swift), [connection](../Sources/LunletClaude/ClaudeStatusLineConnection.swift), [in-place document edit](../Sources/LunletClaude/ClaudeSettingsDocument.swift), [status-line command](../Sources/LunletClaude/ClaudeStatusLineScript.swift), [reader](../Sources/LunletClaude/ClaudePlanLimitsReader.swift), [window readings](../Sources/LunletCore/AccountLimits.swift), [wording](../Sources/LunletDesktop/ClaudeLimitsPresentation.swift), [model](../Sources/LunletDesktop/ClaudePlanLimitsModel.swift), [categories](../Sources/LunletCore/LocalUsage.swift), [script](../Tests/LunletClaudeTests/ClaudeStatusLineScriptTests.swift), [connection](../Tests/LunletClaudeTests/ClaudeStatusLineConnectionTests.swift), [reader](../Tests/LunletClaudeTests/ClaudePlanLimitsReaderTests.swift), [presentation, forecast and model](../Tests/LunletDesktopTests/ClaudeLimitsPresentationTests.swift), [limits group](../Sources/LunletDesktop/PanelStyle.swift), [shared trend chart](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [agent colors](../Sources/LunletDesktop/AllowancePalette.swift), [Codex fit](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [panel heights](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [`AllowanceBar`](../Sources/LunletDesktop/WeeklyAllowanceBar.swift), [profile reader](../Sources/LunletClaude/ClaudeAccountProfile.swift), [Tests](../Tests/LunletClaudeTests/ClaudeAccountProfileTests.swift).

### US-23: Find the right session in a large list

Status: Confirmed.

**As a developer with many sessions, I want clearly separated active work and local history with identifiable conversations, so that I can quickly inspect the correct conversation.**

- **AC-23.01**: **Given** many observed conversations, **When** I switch between Active and History, **Then** sessions remain identifiable even when projects or titles are identical, without a search or state-filter control.
- **AC-23.02**: **Given** either session view, **When** new input or completion arrives, **Then** presentation and ordering do not change session identity, Clear semantics, or the destination of a mobile card.
- **AC-23.03**: **Given** a session row with source-reported activity time, **When** I scan the list, **Then** it shows a compact relative age such as "2m"; unavailable activity time shows no age rather than an invented one.

Implementation: [Presentation ordering](../Sources/LunletDesktop/SessionOrdering.swift), [The session header](../Sources/LunletDesktop/SessionListHeader.swift), [Regressions](../Tests/LunletDesktopTests/SessionOrderingTests.swift), [rows](../Sources/LunletDesktop/SessionPanel.swift), [Tests](../Tests/LunletDesktopTests/PanelStyleTests.swift).

## EPIC-02: Understand allowance and recorded usage

Outcome: Judge remaining account allowance and local consumption using reported values and clearly qualified estimates.

### US-04: Understand account limits and session usage

Status: Confirmed.

Product page: #limits.

**As a developer, I want to see trustworthy limits and usage with their source and freshness, so that I can judge whether my work can continue.**

Acceptance criteria:

- **AC-04.01**: **Given** the source provides account quota windows, **When** I inspect limits, **Then** Lunlet shows the supported remaining allowance, reset time, source and freshness separately from session state. The weekly reset row shows an approximate countdown to the hour alongside a compact calendar date and time to the minute; elapsed reset timestamps are marked due, without assuming that quota has refreshed. The Codex page uses a compact relative Updated label tied to its last successful account snapshot instead of a persistent Received timestamp; opening the panel or starting a failed refresh does not reset it; freshness remains in help text and a compact global Refresh action is available in the outer header next to Settings, covering account information, local usage history, and any connected session source without changing view or clearing sessions. Concurrent refreshes are prevented; unavailable integrations remain explicit.
- **AC-04.02**: **Given** session token or cost information is available, **When** it is displayed, **Then** account quota, session usage, actual billing, and token-based cost estimates are clearly distinguished. Each session row shows recorded tokens and equivalent estimated USD together, without a metric toggle; missing token categories, model prices, or usage records remain unavailable. Where only part of the usage can be priced, a known subtotal may be shown with explicit price coverage; the full cost remains unknown. Visible session amounts use compact monetary precision while help retains the precise estimate and coverage.
- **AC-04.03**: **Given** a value is unavailable or a refresh fails, **When** the panel renders, **Then** an unknown or stale value is identified as such and is not replaced with zero.
- **AC-04.04**: **Given** Lunlet starts with a local Codex sign-in, **When** it reads account usage automatically, **Then** no user enable/stop switch is required; settings briefly explains the source, purpose, and request destination in a low-emphasis footer, with credential-handling detail in hover help rather than a dedicated explanation block. Credentials are not exposed or forwarded through Feishu. Quitting cancels owned reads.
- **AC-04.05**: **Given** limits are being monitored, **When** Lunlet schedules refreshes, **Then** it avoids unnecessary frequent polling and repeated notifications; refresh frequency and overhead are recorded during validation.
- **AC-04.06**: **Given** the official account interface provides available earned-reset entitlements, **When** I inspect usage, **Then** Lunlet shows the reported count and any supplied expiration details separately from remaining allowance; missing count or details remain unknown, and Lunlet does not infer an unannounced global reset or redeem an entitlement.
- **AC-04.07**: **Given** an officially reported seven-day quota window, **When** I open the panel, **Then** a compact progress bar shows its derived remaining percentage and reset time above the session list. Identify the weekly window by its reported duration, not whether it is named primary or secondary. Missing weekly data remains unavailable rather than substituting a different window.
- **AC-04.08**: **Given** trustworthy per-day usage records, **When** I inspect daily usage, **Then** hovering over the usage block opens a separate floating chart to the left of the overview, without clicking or navigating away, for the selected one-to-seven local calendar days under US-18, defaulting to today and the previous four days, with Token and Cost switching. Moving into the chart keeps both it and the overview open; leaving the anchor and chart dismisses it after a short grace period. Screen bounds may require a fallback placement. Token counts come from local Codex usage records; cost is an estimate at published standard API rates, not a subscription bill. Local history is labeled This Mac, separate from account quota and other devices. Missing records or prices remain unavailable. Do not subtract rolling quota snapshots to fabricate daily consumption.

Design note: the hover chart aligns with the bottom of the overview and shows both charts without scrolling, within the visible screen; Token/Cost uses the session tabs' capsule style.

- **AC-04.09**: **Given** the account interface supplies identity, plan, or credit balance, **When** I inspect usage, **Then** the account email or supplied username and reported plan appear above allowance, and Credits remain separate from earned reset entitlements. Earned reset credits show the reported remaining count and compact per-credit expiry countdowns beside Credits, with full dates in hover details. Reset entitlements are passive text, with no refresh-style icon or click action. Credit balances use grouping and at most two decimal places; tiny nonzero values remain visibly nonzero. Missing fields stay unknown; plan multipliers and currency are not inferred.
- **AC-04.10**: **Given** a reported weekly allowance and the vine skin, **When** I inspect its remaining-progress bar, **Then** both the outer vine and expanded straight bar share the same remaining value, gradient palette, proportional marks at 20%, 40%, 60%, and 80%, and the red 10% low-allowance mark; every Codex and Claude meter in the panel and the Overview shows remaining allowance with the same marks. Colors transition continuously from the default blue-purple or the selected normal tint under US-16 toward yellow below 20% and toward deeper red below 10%. Unknown data does not display a remaining fill. No exhaustion forecast or daily-consumption claim is implied.

- **AC-04.11**: **Given** locally recorded usage from any Codex client or task source, **When** Lunlet aggregates usage, **Then** tokens and estimated costs include those records regardless of source label, deduplicate copies of the same session across discovered accounting roots and archives, and preserve unknown pricing and incomplete-coverage distinctions. Account quota remains separate from this Mac's recorded usage.
- **AC-04.12**: **Given** an account, usage or connection value is unavailable after a failed read, **When** it is shown, **Then** it stays unknown and states that Refresh can try again, without automatic retries or polling.
- **AC-04.13**: **Given** the vine skin with both agents selected, **When** the compact entry is shown, **Then** two intertwined strands replace the single outer vine: one shows Codex's weekly remaining allowance and the other Claude Code's weekly remaining (100% minus the seven-day percent used), each in its AC-16.03 color with the shared 20/40/60/80 marks and 10% warning, and each keeps its own unknown state. The two are never combined into one value. With one agent selected the single vine shows that agent. With both agents and the lantern skin, two cords hang from the same wing attachments and cross once under the notch, each carrying five smaller lanterns for one agent — Codex's in the skin's glass, Claude Code's in its AC-16.03 sibling color — interleaved along the width and lit by that agent's own remaining as in AC-17.05; one agent keeps the single cord.

Design note: the usage chart floats to the left of the overview on hover rather than replacing it, Refresh is global at the outer level, and the unfolded layout keeps vertical spacing below the hardware notch tight.

Implementation: [typed quota values](../Sources/LunletCore/AccountLimits.swift), [Codex quota decoding](../Sources/LunletCodex/AccountLimitsDecoder.swift), [decoder tests](../Tests/LunletCodexTests/AccountLimitsDecoderTests.swift), [bounded read-only Codex client](../Sources/LunletCodex/CodexAccountClient.swift), [synthetic subprocess tests](../Tests/LunletCodexTests/CodexAccountClientTests.swift), [compact weekly summary](../Sources/LunletDesktop/AccountUsageSummary.swift), [duration-based selection tests](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [presenter tests](../Tests/LunletDesktopTests/AccountUsageModelTests.swift), [local reader](../Sources/LunletCodex/LocalUsageHistory.swift), [left hover panel](../Sources/LunletDesktop/UsageHoverPanelController.swift), [Accounting tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [history model tests](../Tests/LunletDesktopTests/LocalUsageModelTests.swift), [native hover tests](../Tests/LunletDesktopTests/UsageHoverPanelTests.swift), [usage chart](../Sources/LunletDesktop/UsageHistoryPanel.swift), [trend](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [Claude card and Overview](../Sources/LunletDesktop/ProviderSummaries.swift), [session list](../Sources/LunletDesktop/SessionPanel.swift), [entry](../Sources/LunletDesktop/LettermarkView.swift), [centerline](../Sources/LunletDesktop/VineGeometry.swift), [entry controller](../Sources/LunletDesktop/NotchEntryController.swift), [runtime's](../Sources/LunletDesktop/CompanionRuntime.swift), [Entry tests](../Tests/LunletDesktopTests/VineEntryTests.swift), [controller test](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [`agentVariant`](../Sources/LunletDesktop/AllowancePalette.swift), [tested](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [meters](../Sources/LunletDesktop/WeeklyAllowanceBar.swift), [Usage Settings](../Sources/LunletDesktop/PreferencesPane.swift).

### US-32: Understand weekly allowance pace

Status: Confirmed.

**As a developer, I want to compare my observed weekly allowance with an estimated consumption pace, so that I can judge whether my allowance is likely to last until reset.**

- **AC-32.01**: **Given** comparable official quota observations in the same weekly window, **When** I inspect the weekly trend, **Then** I can distinguish observed remaining allowance from an estimated future trajectory and the reset time.
- **AC-32.02**: **Given** sufficient recent observations and a usable reset time, **When** the estimate indicates exhaustion before reset, **Then** the estimated exhaustion time is labeled as a projection; otherwise the view shows the estimated remaining percentage at reset, without guaranteeing future behavior. Recalculate as new observations arrive and when the view is opened.
- **AC-32.03**: **Given** missing, stale, sparse, conflicting or reset-crossing observations, **When** I inspect the trend, **Then** unavailable periods are not invented and an unsupported forecast is not shown.
- **AC-32.04**: **Given** the existing local Token/Cost chart, **When** weekly allowance is shown, **Then** account quota percentages remain separate from local token counts and API-price cost estimates; the charts do not imply that either local measure equals account consumption.
- **AC-32.05**: **Given** a comparable reading and a reported seven-day reset, **When** I inspect the trend, **Then** remaining is compared with the even budget at that reading's time, is not labeled a forecast, stays visible when no forecast is shown, and is omitted after a detected mid-window increase.
- **AC-32.06**: **Given** a forecast, **When** it is shown, **Then** the chart draws it as a central estimate and shaded range from the latest reading without a separate forecast sentence; hovering the estimate region, and VoiceOver, state the estimated range of remaining at reset or the estimated run-out time with its earliest plausible time; estimates with less than a day of current-window evidence, or that ignore the previous window, are labeled rough, and no range is presented as a guarantee.
- **AC-32.07**: **Given** the latest reading is more than one hour old, **When** the forecast is shown, **Then** it starts at that reading and states its time; a reading more than 24 hours old, a passed reset, or no successful account read identifying the window produces no forecast and states the reason, while a failed account read does not hide an estimate built from earlier same-window readings and labels it stale.
- **AC-32.08**: **Given** fewer than six hours of current-window readings and no usable earlier window, **When** I inspect the trend, **Then** it shows that it is too early to estimate; **Given** no decrease across at least a day of readings, **Then** the estimate equals the current remaining; **Given** a 0% reading, **Then** the trend shows the observed run-out and reset time rather than a projection.

Implementation: [Independent quota estimation](../Sources/LunletCore/WeeklyQuotaEstimator.swift), [local history matching](../Sources/LunletDesktop/WeeklyQuotaTrend.swift), [recorded quota extraction](../Sources/LunletCodex/LocalUsageHistory.swift), [hover chart](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [Estimator tests](../Tests/LunletDesktopTests/WeeklyQuotaTrendTests.swift), [local reader tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [synthetic panel rendering](../Tests/LunletDesktopTests/WeeklyQuotaTrendPanelTests.swift), [account model](../Sources/LunletDesktop/AccountUsageModel.swift), [Estimator tests](../Tests/LunletCoreTests/QuotaPaceEstimatorTests.swift), [stale-read model test](../Tests/LunletDesktopTests/AccountUsageModelTests.swift).

Design note: show a clearly labeled weekly usage forecast with three lines on an axis covering each calendar date through the reset: an even ideal budget from 100% at the start of the current seven-day window to 0% at reset, a solid line of locally recorded daily allowance observations, and a dashed forecast. Label percentage ticks every 20% with light dotted grid lines. Daily points can show separate reset windows; preserve the recorded points immediately before and after each detected reset, restrict displayed observations to the selected number of local calendar days including today, and do not invent values for missing dates; forecast inputs do not depend on the displayed range. Forecasts use every comparable official reading from the past seven days at its recorded resolution, including account reads and readings recorded on this Mac, not the daily chart points. They compare changes only within matching reset windows and never count a reset jump, the interval containing it, or time spent at 0% as consumption. For pace only, a reported reset minus seven days is treated as that window's 100% start unless a reading contradicts it; it is never drawn as a reading. Vertical dashed markers show detected reset transitions and the next scheduled reset; inferred historical times are explicitly approximate in chart help. Reset timestamps within five minutes are treated as the same window to tolerate observed timestamp drift. Pace is the calendar rate over the past seven days, so daily and weekly patterns average out. When this window's use so far differs from the same hours one week earlier by more than a factor of two, the earlier window is ignored and the estimate is labeled rough until a day of data exists. The forecast starts at the latest comparable reading, assumes no additional reset before the reported reset, and is recalculated when a reading arrives. Hovering a reset line displays its time; inferred times are labeled approximate. Historical rollout records do not identify the account; matching bucket, reset and available plan is not proof of account identity. Missing or inconsistent data does not produce a forecast; AC-32.06 through AC-32.08 define the range, staleness, early-window and exhausted states. The independent estimator does not attribute quota changes to individual models or infer quota from token totals.

### US-18: Choose the usage history range

Status: Confirmed.

**As a developer, I want to choose in Settings how many days the usage chart displays, so that the chart shows the time range I find useful.**

Acceptance criteria:

- **AC-18.01**: **Given** usage settings, **When** I select a history range, **Then** supported values are the integers 1 through 7 inclusive.
- **AC-18.02**: **Given** a selected range, **When** I open the usage chart, **Then** it displays that number of local calendar days and adapts bar widths, spacing, and labels to remain readable.
- **AC-18.03**: **Given** Token and Cost views, **When** I switch the chart metric, **Then** both views use the same selected date range and retain existing unknown-data and estimate distinctions.

Five local calendar days are the default; Settings offers the one-to-seven-day range.

Implementation: [The bounded reader](../Sources/LunletCodex/LocalUsageHistory.swift), [chart](../Sources/LunletDesktop/UsageHistoryPanel.swift), [Reader range tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [model cancellation tests](../Tests/LunletDesktopTests/LocalUsageModelTests.swift).

## EPIC-03: Connect one private channel and receive useful updates

Outcome: Reach the owner through one selected messenger, with minimal setup and truthful readiness at each stage.

### US-01: Connect Feishu with minimal setup

Status: Confirmed.

**As a developer, I want to connect my own Feishu bot by scanning and authorizing, so that I can enable mobile continuation without configuring developer infrastructure manually.**

Acceptance criteria:

- **AC-01.01**: **Given** Feishu is not connected, **When** I choose Connect Feishu, **Then** Lunlet presents the official application authorization flow with a choice of an eligible existing application or a new one; it does not force creation.
- **AC-01.02**: **Given** I scan and authorize successfully, **When** setup completes, **Then** Lunlet obtains the user-owned application's credentials, stores them on this Mac in Lunlet's credential file that only my user account can read (never in preferences, exports or skin files), prepares the required configuration, and reports connection status. Owner decision 2026-11-01: the credential file replaces the Keychain so that updates of an unsigned build never ask for authorization again; a Keychain store remains for a later signed release, and credentials an earlier build saved in the Keychain are moved into the file on first use, silently when the build may read them and otherwise through Authorize access once.
- **AC-01.03**: **Given** a normal setup, **When** I follow the flow, **Then** I do not need to create an application in the developer console, select individual permissions, or copy secrets manually.
- **AC-01.04**: **Given** authorization is denied, expires, or is blocked by organization permissions, **When** setup cannot finish, **Then** Lunlet explains the failure and offers a recoverable next step without claiming success.
- **AC-01.05**: **Given** Feishu setup succeeds, **When** mobile access is configured, **Then** Lunlet binds it to the verified owner identity for that application and requests only necessary messaging permissions, without unrelated calendar or document access.
- **AC-01.06**: **Given** connection and privacy information is presented, **When** I review the access boundary, **Then** Lunlet explains its owner access controls and applicable organization restrictions without claiming that a user-owned bot is immune to Feishu administration.

- **AC-01.07**: **Given** I choose an existing application, **When** the official authorization page prepares configuration changes, **Then** I review and confirm them there before Lunlet accepts the returned credentials; the same verified identity and secure-storage rules apply to both existing and new applications.

- **AC-01.08**: **Given** the desktop panel, **When** I need Feishu setup, **Then** a compact rounded footer button with a connection-state symbol, channel name, expansion indicator, and subtle hover feedback opens an attached connection card with both a QR code and an official web link. The main overview and settings do not contain a large onboarding block. After authorization the entry identifies Feishu or Lark from the saved enrollment; only a verified live connection may be labeled connected.

Implementation: [registration state machine](../Sources/LunletFeishu/RegistrationFlow.swift), [minimal manifest](../Sources/LunletFeishu/RegistrationManifest.swift), [bounded native HTTP client](../Sources/LunletFeishu/RegistrationClient.swift), [credential file](../Sources/LunletSecureStorage/CredentialFileStore.swift), [file and migrating enrollment stores](../Sources/LunletFeishu/EnrollmentStore.swift), [file store tests](../Tests/LunletSecureStorageTests/CredentialFileStoreTests.swift), [migration tests](../Tests/LunletFeishuTests/FileEnrollmentStoreTests.swift), [Keychain store](../Sources/LunletFeishu/EnrollmentStore.swift), [protocol and HTTP tests](../Tests/LunletFeishuTests/RegistrationClientTests.swift), [attached onboarding card](../Sources/LunletDesktop/FeishuSetupPanel.swift), [setup tests](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [owner-message client](../Sources/LunletFeishu/BotClient.swift), [endpoint discovery](../Sources/LunletFeishu/ConnectionEndpoint.swift), [long-connection runner](../Sources/LunletFeishu/FeishuConnectionRunner.swift), [native loopback transport](../Tests/LunletFeishuTests/FeishuSocketTests.swift), [Synthetic namespace compatibility tests](../Tests/LunletFeishuTests/EnrollmentStoreTests.swift).

### US-20: Choose one mobile communication channel

Status: Confirmed.

Product page: #away.

**As a developer, I want to select one supported communication channel in Settings, so that Lunlet sends notifications and supported replies through my preferred service.**

Acceptance criteria:

- **AC-20.01**: **Given** communication settings, **When** I choose a channel, **Then** only one channel is selected at a time, from Feishu/Lark, Slack, and Telegram, with no WhatsApp entry.
- **AC-20.02**: **Given** a selected channel, **When** I open the desktop panel, **Then** its compact lower-left connection entry identifies that service and its actual connection state.
- **AC-20.03**: **Given** an eligible session notification, **When** mobile delivery and replies are enabled for the selected channel, **Then** they use that channel while retaining owner verification and exact session, turn, and request binding; ordinary chat messages do not become ambiguous session input.

- **AC-20.04**: **Given** Slack or Telegram setup, **When** I enter my own bot credentials and prove possession of a private conversation using a fresh, expiring pairing code shown on my Mac, **Then** Lunlet binds notifications to that verified private recipient and stores credentials on this Mac in Lunlet's user-only credential file (the Keychain store remains for a later signed release; see AC-01.02); group chats, stale codes and unrelated users do not bind it. No public server is required. Slack uses Socket Mode; Telegram uses long polling during pairing and preserves existing webhooks. Each credential field identifies the exact provider menu used to obtain it; setup does not assume that developers already know the token terminology. Credentials I have typed stay in the card until I connect, cancel or switch channel, even when the panel closes while I copy the next one.
- **AC-20.05**: **Given** setup, notification delivery or saved authorization, **When** I change channels, cancel setup, disconnect or quit, **Then** obsolete work cannot activate a different channel or update current delivery state; pending network work is canceled and owned resources are joined. Saved authorization alone never claims delivery success.
- **AC-20.06**: **Given** supported credentials, **When** authorization is checked or a completion is delivered, **Then** only verified provider identities and matching private-chat receipts establish the respective stage. An uncertain send is not automatically retried. Background credential reads remain silent; access prompts require an explicit owner action.

Implementation: [provider adapters](../Sources/LunletMessaging/SlackBotClient.swift), [Telegram client](../Sources/LunletMessaging/TelegramBotClient.swift), [shared bounded network owner](../Sources/LunletMessaging/ChannelHTTPClient.swift), [file, migrating and Keychain credential stores](../Sources/LunletMessaging/ChannelCredentialStore.swift), [file store tests](../Tests/LunletMessagingTests/FileChannelCredentialStoreTests.swift), [native setup](../Sources/LunletDesktop/BotChannelSetupModel.swift), [selected-channel runtime](../Sources/LunletDesktop/CompanionRuntime.swift), [Provider tests](../Tests/LunletMessagingTests/SlackBotClientTests.swift), [Telegram expiry/receipt tests](../Tests/LunletMessagingTests/TelegramBotClientTests.swift), [storage tests](../Tests/LunletMessagingTests/ChannelCredentialStoreTests.swift), [setup lifecycle tests](../Tests/LunletDesktopTests/BotChannelSetupModelTests.swift), [runtime regressions](../Tests/LunletDesktopTests/CompanionRuntimeTests.swift), [Setup instructions](messaging.md), [shared secure storage](../Sources/LunletSecureStorage/SecureItemStore.swift), [application menu](../Sources/LunletDesktop/ApplicationMenu.swift) and its [test](../Tests/LunletDesktopTests/ApplicationMenuTests.swift), which route Cmd-V and the other edit keys into the token fields.

### US-22: Understand readiness and recover from a blocked connection

Status: Confirmed.

**As a developer, I want a compact view of authorization, notification delivery, reply reception, and session-input readiness, so that I can resolve the actual blocker without repeating unrelated setup.**

- **AC-22.01**: **Given** a partially configured integration, **When** I inspect its connection details, **Then** each supported stage has its own factual state and an actionable recovery step rather than a blanket connected label.
- **AC-22.02**: **Given** a denied credential read or failed delivery, **When** I choose the relevant recovery action, **Then** the result updates that stage without resetting the bot or unrelated local session state.
- **AC-22.03**: **Given** the attached connection card and a saved connection, **When** I open it, **Then** it shows the same factual readiness stages as Settings, listing only stages this build supports, each colored by state — green for verified facts (credentials accepted, private chat paired, a notification delivered), blue while in progress or armed, orange when I must act, red when a step failed, gray when not set up — and the footer shows the channel's overall state, taken from its worst stage, as a colored icon without words; replies and session input are never implied by these colors. Before a connection is saved the card gives that room to the setup steps instead.

This refines US-01, US-10, and US-14. No new credential prompt, automatic retry of uncertain delivery, or diagnostic export is approved.

Implementation: [Connection readiness](../Sources/LunletDesktop/FeishuSetupModel.swift), [Messaging settings](../Sources/LunletDesktop/PreferencesPane.swift), [The regression](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [HTTP boundary tests](../Tests/LunletFeishuTests/BotClientTests.swift), [coordinator regressions](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [stage list](../Sources/LunletDesktop/CompanionPanel.swift), [Slack/Telegram](../Sources/LunletDesktop/BotChannelSetupModel.swift), [bot](../Tests/LunletDesktopTests/BotChannelSetupModelTests.swift).

### US-05: Keep mobile continuation available for all active sessions

Status: Confirmed.

Product page: #away.

**As a developer, I want mobile continuation to cover all active sessions and keep the Mac reachable, so that I can step away without configuring individual sessions or power settings.**

Acceptance criteria:

- **AC-05.01**: **Given** Away Mode is off and Feishu is connected, **When** it is enabled, **Then** notifications cover all observable active sessions automatically, including sessions discovered while the mode remains enabled; supported mobile continuation is available only for independently eligible original CLI sessions.
- **AC-05.02**: **Given** active sessions are already waiting for input or idle after a finished turn, **When** I enable Away Mode, **Then** their current state and independently eligible continuation controls become available in Feishu without waiting for another session event; these initial-state cards are not replayed completion notifications, and pending execution approvals remain Mac-only.
- **AC-05.03**: **Given** Feishu setup is incomplete or its connection is unavailable, **When** I try to enable mobile continuation, **Then** Lunlet explains what is unavailable without reporting remote access as ready; local session monitoring remains available.
- **AC-05.04**: **Given** Away Mode is on, **When** work is running, waiting, or idle after a turn, **Then** Lunlet prevents idle system sleep while allowing screen locking and display sleep.
- **AC-05.05**: **Given** Away Mode is on, **When** it is disabled or I quit Lunlet, **Then** Lunlet releases its sleep-prevention request and restores the system's normal power behavior.
- **AC-05.06**: **Given** saved owner authorization, **When** the Mac is confirmed locked, **Then** completion notifications activate automatically; unlocking, disconnecting, or quitting stops delivery. Unknown lock state does not enable delivery. Remote input retains its independent eligibility checks.

- **AC-05.07**: **Given** the main panel, **When** I inspect mobile access, **Then** it has no Away Mode toggle; any future behavior configuration belongs in settings.
- **AC-05.08**: **Given** messaging settings, **When** I inspect phone replies, **Then** a switch allows replies from my phone, enabled by default; turning it off rejects new mobile input and invalidates every issued reply control under AC-12.02, without stopping completion notifications.
- **AC-05.09**: **Given** phone replies are allowed, saved owner authorization and a confirmed locked Mac, **When** an eligible original CLI session finishes a turn or asks an ordinary question, **Then** its card may carry single-use reply controls; **When** the Mac unlocks, **Then** remaining controls stop working and later submissions receive an accurate rejection. Execution approvals remain Mac-only and ineligible sessions stay notification-only.

Scope of AC-05.01 through AC-05.05: these are required logical continuation transitions, not an approved manual toggle or a claim that locking enables input.

Implementation: [owned idle-sleep assertion](../Sources/LunletDesktop/IdleSleepAssertion.swift), [opt-in runtime test](../Tests/LunletDesktopTests/IdleSleepAssertionTests.swift), [mobile coordinator](../Sources/LunletFeishu/MobileCoordinator.swift), [synthetic tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift), [Away model](../Sources/LunletDesktop/AwayModeModel.swift), [tests](../Tests/LunletDesktopTests/AwayModeModelTests.swift), [notification owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [Feishu sender](../Sources/LunletDesktop/FeishuCompletionSender.swift), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [Service tests](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [flow tests](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift), [completion card](../Sources/LunletFeishu/SessionCard.swift), [kept beside the enrollment](../Sources/LunletDesktop/FeishuOwnerMemory.swift), [test](../Tests/LunletDesktopTests/FeishuOwnerMemoryTests.swift).

### US-06: Receive concise, actionable notifications

Status: Confirmed.

Product page: #away.

**As a developer, I want short Feishu summaries when work finishes, fails, or needs me, so that I can decide what to do next without reading the full conversation.**

Acceptance criteria:

- **AC-06.01**: **Given** Away Mode is on, **When** a monitored session finishes a turn, fails, asks an ordinary question, or needs execution approval, **Then** its notification identifies the project and session and explains the event with necessary context.
- **AC-06.02**: **Given** a completion notification, **When** I read it, **Then** every channel shows, in the same order: a header colored or marked by the evidenced outcome (succeeded, failed, stopped, finished without an outcome, or needing me on the Mac) naming the project, then the agent with the session title — or a short form of my request when the title is only a placeholder; an excerpt of my latest request of about 140 characters; and the agent's complete final reply with its Markdown kept readable, shortened only to fit that channel's message limit and then ending with "… The rest is on your Mac.", or an honest line when no reply was captured. On Slack and Telegram the notice shows the agent and the event with the project as its heading, the session title when it is not a placeholder, the request as a quote, the reply, any notes and, when the notice can take a reply, one line saying how (US-36); it has no footer, because those channels show the time themselves. The Feishu card follows Feishu's own card conventions instead: a header tinted by the outcome whose title names the agent and the event, such as "Codex finished", with the project, the session title when it is not a placeholder and the local time as the subtitle, and the reply's state as a tag; the request in a tinted block labeled "You asked"; the reply in a bordered block labeled with the agent, with any notes kept inside it; no divider and no footer. A Claude Code card ends with a quiet line that replies from my phone are not available yet; a Codex card says nothing, because its reply box may still be added.
- **AC-06.03**: **Given** the first-release summary path, **When** a notification is prepared, **Then** Lunlet prioritizes existing public Codex conclusions and confirmed state without requiring another model account, API key, or paid summarization service.
- **AC-06.04**: **Given** a question cannot be presented safely within a concise message, **When** Lunlet notifies me, **Then** it asks me to return to the Mac rather than omitting context needed for a reliable answer.
- **AC-06.05**: **Given** a notification or question card is prepared, **When** Lunlet sends it to the selected channel, **Then** it goes only to my own paired bot and private chat and carries only the request excerpt, the final reply and the question context of AC-06.02 and AC-06.04; secret-looking values and hidden reasoning are removed and home folders shortened, and Lunlet never adds credentials, authentication files, tool output, files or the rest of the conversation.

Implementation: [Codex reader](../Sources/LunletCodex/CodexSessionReader.swift), [Claude reader](../Sources/LunletClaude/ClaudeTranscriptReader.swift), [observation owner](../Sources/LunletDesktop/SessionObservationModel.swift), [`SessionNotice`](../Sources/LunletCore/SessionSnapshot.swift), [`NoticeText`](../Sources/LunletCore/NoticeText.swift), [Feishu card](../Sources/LunletFeishu/SessionCard.swift), [Slack](../Sources/LunletMessaging/SlackNoticeMessage.swift), [Telegram](../Sources/LunletMessaging/TelegramNoticeMessage.swift), [notice](../Tests/LunletCoreTests/SessionNoticeTests.swift), [text shaping](../Tests/LunletCoreTests/NoticeTextTests.swift), [card](../Tests/LunletFeishuTests/SessionCardTests.swift), [Slack and Telegram](../Tests/LunletMessagingTests/NoticeMessageTests.swift), [Codex](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [Claude](../Tests/LunletClaudeTests/ClaudeTranscriptReaderTests.swift), [preview render](../Tests/LunletDesktopTests/NoticePreviewRenderTests.swift), [locked completion owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [Regressions](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [owner-only card delivery](../Sources/LunletFeishu/BotClient.swift), [synthetic HTTP tests](../Tests/LunletFeishuTests/BotClientTests.swift).

## EPIC-04: Continue the correct existing CLI conversation safely

Outcome: Move an unfinished task forward from its bound card while retaining its original context and authority.

### US-07: Answer an ordinary question from mobile

Status: Confirmed.

**As a developer, I want to answer the current question from its Feishu card, so that the original session can continue while I am away.**

Acceptance criteria:

- **AC-07.01**: **Given** a verified ordinary question is pending, **When** I open its card, **Then** I see sufficient question context and the applicable options or text input.
- **AC-07.02**: **Given** I submit an answer, **When** Lunlet forwards it, **Then** it targets that exact session, turn, and pending request and retains the original context.
- **AC-07.03**: **Given** the question was already answered, cancelled, expired, or superseded, **When** I submit its old card, **Then** no answer is forwarded and I receive an explanation.
- **AC-07.04**: **Given** the request may authorize execution or its purpose cannot be established, **When** Lunlet evaluates it, **Then** mobile answering is unavailable even if the protocol calls it a user-input request.
- **AC-07.05**: **Given** multiple monitored sessions, **When** I answer from mobile, **Then** only a submission from the corresponding notification card can target its bound session, turn, and question request. Ordinary bot-chat messages, including quoted replies outside the card form, do not trigger Codex input.

Implementation: [continuation gate](../Sources/LunletCore/ContinuationGate.swift), [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [card renderer and tests](../Tests/LunletFeishuTests/SessionCardTests.swift), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift).

The [callback decoder](../Sources/LunletFeishu/CardCallback.swift), [typed form mapping](../Sources/LunletFeishu/CardForm.swift), and [serialized router](../Sources/LunletFeishu/CardActionRouter.swift) connect synthetic provider callbacks to the gate. [Router tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) verify exact question IDs, permitted options, stale controls, and Mac-only approval handling. Question presentation and provenance remain outstanding; authenticated ingress and Codex dispatch are shared with the US-08 follow-up path.

### US-08: Send a follow-up to the same session

Status: Confirmed.

Product page: #away.

**As a developer, I want to add a follow-up instruction after a turn finishes, so that I can move the unfinished task forward in the same conversation.**

Acceptance criteria:

- **AC-08.01**: **Given** the original CLI session is still open and ready for follow-up, **When** I submit an instruction from its Feishu card, **Then** the next turn uses that session's identity and existing context.
- **AC-08.02**: **Given** the instruction is accepted, **When** Codex processes it, **Then** its existing sandbox and approval policy remain in force.
- **AC-08.03**: **Given** the session has ended, is executing a new turn, or is waiting for execution approval, **When** I submit a stale follow-up card, **Then** Lunlet does not start a new session, take over the running turn, or treat the instruction as approval.
- **AC-08.04**: **Given** the next turn produces a result, **When** it is available, **Then** its notification and receipt remain associated with the original session.
- **AC-08.05**: **Given** a completion card with an eligible follow-up form, **When** I submit an instruction, **Then** Lunlet resolves its target from the issued card control and authenticated message binding, never from the latest active session or bot-chat ordering. A card for one session cannot submit to another.

Implementation: [session monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [queue adapter](../Sources/LunletCodex/CodexQueueAdapter.swift), [process reader](../Sources/LunletCodex/CodexProcessReader.swift), [rollout watch](../Sources/LunletCodex/CodexDeliveryWatch.swift), [Session-named receipts](../Sources/LunletFeishu/ReplyReceiptCard.swift), [adapter and process runner](../Tests/LunletCodexTests/CodexQueueAdapterTests.swift), [binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift), [reply service](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [end-to-end flow](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift).

The [continuation gate](../Sources/LunletCore/ContinuationGate.swift) and [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) additionally reject stale follow-up controls when the observed context changes. The [card router](../Sources/LunletFeishu/CardActionRouter.swift) binds follow-up forms to authenticated send receipts and the current connection; [integration tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) keep two sessions with identical turn names separate. The [mobile coordinator and tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) additionally verify publication-to-claim handoff for two sessions with the same turn name.

### US-09: Keep execution approvals on the Mac

Status: Confirmed.

Product page: #away.

**As a developer, I want execution approvals to remain on my computer, so that limited mobile continuation does not broaden the agent's authority.**

Acceptance criteria:

- **AC-09.01**: **Given** Codex needs execution approval, **When** Feishu notifies me, **Then** it asks me to approve on the Mac and provides no mobile approval control.
- **AC-09.02**: **Given** I send text such as "yes" or "continue", **When** an execution approval is pending, **Then** Lunlet does not translate that text into authorization.
- **AC-09.03**: **Given** a follow-up requires an action outside the session's permissions, **When** Codex requests approval, **Then** it waits for the original desktop approval process; Lunlet does not weaken the sandbox or enable automatic approval.

Implementation: [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [gate](../Sources/LunletCore/ContinuationGate.swift), [Card-action tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift), [rendered approval cards](../Sources/LunletFeishu/SessionCard.swift), [rendering tests](../Tests/LunletFeishuTests/SessionCardTests.swift), [live binding](../Sources/LunletCodex/CodexSessionMonitor.swift), [Binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift).

### US-10: Receive reliable action receipts

Status: Confirmed.

**As a developer, I want each mobile action to have a clear outcome and execute at most once, so that I can trust the result despite retries or repeated taps.**

Acceptance criteria:

- **AC-10.01**: **Given** an action is received, **When** its status changes, **Then** the receipt distinguishes received, submitted to Codex, processing confirmed, and failure; transport success alone is not task success.
- **AC-10.02**: **Given** a duplicate callback, repeated tap, or out-of-order operation, **When** it arrives, **Then** it cannot cause duplicate execution or answer a later request accidentally.
- **AC-10.03**: **Given** submission times out and the outcome is unknown, **When** Lunlet reports the result, **Then** it states that uncertainty and does not blindly resubmit.
- **AC-10.04**: **Given** a mobile action arrives, **When** Lunlet validates it, **Then** input is forwarded only if the owner and application, local installation, session, turn or request, and validity period all match the current eligible state; unauthorized, mismatched, or expired actions are rejected without guessing a foreground destination.

Implementation: [gate](../Sources/LunletCore/ContinuationGate.swift), [typed models](../Sources/LunletCore/ContinuationModels.swift), [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [Provider decoding tests](../Tests/LunletFeishuTests/CardCallbackTests.swift), [router tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift), [Traceability checks](../scripts/check_traceability.py), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [receipt card](../Sources/LunletFeishu/ReplyReceiptCard.swift), [service](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [adapter](../Tests/LunletCodexTests/CodexQueueAdapterTests.swift), [flow](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift).

The [frame assembler](../Sources/LunletFeishu/FrameAssembler.swift) and [wire tests](../Tests/LunletFeishuTests/FrameAssemblerTests.swift) verify bounded fragment assembly and acknowledgments without losing 64-bit identity. The [native socket tests](../Tests/LunletFeishuTests/FeishuSocketTests.swift) verify one authorization for a repeated bound callback and no action from malformed input. A provider acknowledgment remains distinct from Codex submission and processing. The [coordinator](../Sources/LunletFeishu/MobileCoordinator.swift) applies atomic revisioned router state and claims each accepted action once immediately before adapter handoff; [tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) reject delayed synchronization and queued actions after access changes or an observation outage, even if the original state returns. Current transport verification is recorded in [feasibility](feasibility.md#messaging-channels).

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

Implementation: [binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift), [router](../Tests/LunletFeishuTests/CardActionRouterTests.swift).

The [core gate and tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) now reject unverified lifecycle evidence and permanently retire an ended connection identity. Restoring a session requires a fresh verified connection. The [coordinator](../Sources/LunletFeishu/MobileCoordinator.swift) preserves observed end-of-session tombstones and forwards lifecycle invalidation into the router; [regressions](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) reject a delayed alive snapshot for an ended binding. Actual lifecycle detection remains an integration responsibility.

The [card router](../Sources/LunletFeishu/CardActionRouter.swift) requires fresh observations and controls after its Feishu connection changes. [Synthetic recovery tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) reject old cards after connection replacement or access changes; the [connection runner tests](../Tests/LunletFeishuTests/FeishuConnectionRunnerTests.swift) verify fresh discovery, retry limits, cancellation, and explicit recovery for authentication/protocol errors. The [native socket](../Sources/LunletFeishu/FeishuSocket.swift) closes on confirmed loss from an owned [network-path observer](../Sources/LunletFeishu/FeishuNetworkPath.swift); injected path-loss tests reject queued callbacks and invalidate old controls. Real network loss/recovery and OS path notifications remain unaccepted.

### US-36: Reply from Slack or Telegram

**As a developer away from my Mac, I want to continue a finished Codex session from a Slack or Telegram notice, so that the two text channels are as useful as the Feishu card.**

Status: Confirmed. Depends on US-20 for the paired private chat, US-08 and US-10 for the continuation and receipt rules, and US-05 for the locked-Mac reply window.

Product page: #away.

Acceptance criteria:

- **AC-36.01**: **Given** Slack or Telegram is the selected channel, the Mac is confirmed locked and an eligible Codex turn finishes, **When** the notice is sent, **Then** it ends with a reply button that opens the reply box (Telegram) or one line inviting a reply in its thread (Slack) within the reply window; a Claude Code notice, a child task or an ineligible session carries no such line.
- **AC-36.02**: **Given** such a notice, **When** a message arrives for the bot, **Then** it is forwarded only if it comes from the paired owner in the paired private chat, answers that notice (Telegram's reply to it or to the prompt its button opened, Slack's thread), was sent within the notice's validity period and while the Mac is still locked, fits one plain-text CLI argument of at most 1,000 characters, and no reply for that turn was accepted before; it then continues that same session through the US-08 path. Any other message is ignored, and a late or repeated reply to a known notice is answered with the reason, never forwarded.
- **AC-36.03**: **Given** an accepted reply, **When** its state changes, **Then** the notice itself is rewritten in place to show received, sent, delivered, not confirmed or not sent with the reason, and an open notice is rewritten as closed when the Mac unlocks, its validity period ends or a newer notice replaces it; a plain line is sent only when the provider refuses the rewrite.
- **AC-36.04**: **Given** no notice can take a reply, **When** Lunlet is idle, **Then** nothing polls or listens for replies; Telegram long polling and Slack Socket Mode run only while a notice is within its validity period, never set a webhook, and keep tokens in Lunlet's user-only credential file.

Implementation: [reply service](../Sources/LunletMessaging/BotReplyService.swift), [notice states](../Sources/LunletMessaging/NoticeReply.swift), [Telegram client](../Sources/LunletMessaging/TelegramBotClient.swift), [Slack client](../Sources/LunletMessaging/SlackBotClient.swift), [channel sender](../Sources/LunletDesktop/OwnerChannelCompletionSender.swift), [product page stills](../Tests/LunletDesktopTests/ChannelChatScenery.swift); [service tests](../Tests/LunletMessagingTests/BotReplyServiceTests.swift), [sender tests](../Tests/LunletDesktopTests/OwnerChannelCompletionSenderTests.swift), [Telegram tests](../Tests/LunletMessagingTests/TelegramBotClientTests.swift), [Slack tests](../Tests/LunletMessagingTests/SlackBotClientTests.swift), [notice tests](../Tests/LunletMessagingTests/NoticeMessageTests.swift).

## EPIC-05: Personalize a focused and durable macOS interface

Outcome: Choose supported presentation and settings without adding clutter, losing preferences or mistaking planned providers for working integrations.

### US-31: Find focused controls in a categorized Settings interface

Status: Confirmed.

**As a developer, I want Lunlet settings grouped by purpose in a native macOS interface, so that I can find and understand its configuration without cluttering the main panel.**

- **AC-31.01**: **Given** an expanded set of preferences, **When** I open Settings, **Then** related options are grouped into focused categories rather than one long undifferentiated list.
- **AC-31.02**: **Given** a settings category, **When** I inspect its controls, **Then** they describe supported behavior and dependencies clearly, without presenting planned or unavailable integrations as working features.
- **AC-31.03**: **Given** the categorized settings, **When** I return to the main panel, **Then** sessions and usage remain the primary content while application configuration stays in Settings.
- **AC-31.04**: **Given** the first-release settings, **When** I open them, **Then** Appearance is the initial category; no empty General category or whole-settings import/export/reset controls are exposed. Skin import/export remains in Appearance and property-level reset remains contextual to its control.

Implementation: [Native categorized preferences](../Sources/LunletDesktop/PreferencesPane.swift).

### US-16: Customize official skin colors

Status: Confirmed.

Product page: #yours.

**As a developer, I want to adjust official notch skin colors in Settings using a macOS-style color control, so that its appearance suits my preferences.**

Acceptance criteria:

- **AC-16.01**: **Given** appearance settings for any official skin, **When** I choose a color, **Then** a continuous color spectrum supports arbitrary hues and a native macOS color picker offers the full RGB range; editing is not limited to presets. The selected color is clear; a compact native Restore button resets the selected official skin directly, without an extra menu or icon. The continuous control retains keyboard adjustment with subtle thumb-only focus feedback rather than a large track outline.
- **AC-16.02**: **Given** a chosen appearance, **When** I view the notch entry, **Then** its lettering and allowance decoration use a coordinated color treatment for every official skin.
- **AC-16.03**: **Given** both agents selected, **When** either agent's allowance or usage appears in the notch strand, a meter, an Overview limit row or a chart segment, **Then** Codex uses the selected palette and Claude Code a clearly distinct sibling of it — turned 70 degrees around the hue circle away from the yellow and orange warning hues, more saturated and deeper, so the two differ in hue and lightness (at least 25 CIEDE2000 apart on the built-in palettes) — so each agent keeps one color everywhere and both change with the skin color; the yellow and red low-allowance colors of AC-04.10 apply unchanged to both.

Before implementation, resolve how user-selected colors interact with the shared allowance palette and existing low-allowance warning colors under AC-04.10. This request does not silently replace those confirmed rules.

Implementation: [Native RGB and continuous color controls](../Sources/LunletDesktop/SkinColorControls.swift), [Appearance](../Sources/LunletDesktop/PreferencesPane.swift), [validated settings](../Sources/LunletDesktop/PreferencesStore.swift), [The shared allowance palette](../Sources/LunletDesktop/AllowancePalette.swift), [Palette regressions](../Tests/LunletDesktopTests/VineEntryTests.swift), [official/imported ownership and lantern rendering](../Tests/LunletDesktopTests/SkinCatalogTests.swift), [continuous hue editing regressions](../Tests/LunletDesktopTests/SkinColorControlsTests.swift).

### US-17: Choose and supply a custom notch skin

Status: Confirmed.

Product page: #yours.

**As a developer, I want to select a built-in notch skin or import my own through configuration, so that I can personalize Lunlet without editing or rebuilding its source code.**

Acceptance criteria:

- **AC-17.01**: **Given** available notch skins, **When** I open appearance settings, **Then** I can choose the skin used by the notch entry.
- **AC-17.02**: **Given** a compatible user-defined style, **When** I add it through the supported configuration or import mechanism, **Then** it becomes selectable without changing Lunlet source code or recompiling the application.
- **AC-17.03**: **Given** an alternative style, **When** it is selected, **Then** device-adaptive notch placement, allowance representation, and entry interaction remain available.
- **AC-17.04**: **Given** the built-in skin selector, **When** this feature is implemented, **Then** it offers the existing vine skin and a red-lantern skin as the two initial choices.
- **AC-17.05**: **Given** the red-lantern skin and known weekly remaining allowance, **When** the compact entry is shown, **Then** five red lanterns replace the outer progress vine between lun and let. Each lantern represents 20 percentage points; as its represented allowance is depleted, its brightness gradually decreases until it is extinguished. All five are lit at 100% and all five are extinguished at 0%.
- **AC-17.06**: **Given** the red-lantern skin, **When** the entry is displayed, **Then** the lun and let lettering is designed to match the lantern scene as one coordinated composition.
- **AC-17.07**: **Given** unavailable allowance data, **When** either skin is displayed, **Then** its unknown state remains distinguishable from a confirmed zero balance.
- **AC-17.08**: **Given** Appearance settings, **When** I select a skin, **Then** all official skins expose the same color controls immediately beside the skin selector, before custom-skin management; later official skins inherit this capability without an ID or skin-kind allowlist. Imported skins own their package colors and do not expose the official palette. Each official skin keeps its own saved color: switching skins shows the selected skin's saved color, or its default when it was never customized, and Restore resets only the selected skin.

The skin package format, local import workflow, supported animation capabilities, compatibility rules, and validation boundaries need design before implementation. Assess how alternate skin semantics interact with AC-04.10 before changing the current allowance presentation. A plugin-style import experience does not authorize an arbitrary executable-code plugin system.

Implementation: [Skin catalog](../Sources/LunletDesktop/SkinCatalog.swift), [native renderer](../Sources/LunletDesktop/LettermarkView.swift), [lantern scene](../Sources/LunletDesktop/LanternScene.swift), [format guide](skins.md), [catalog tests](../Tests/LunletDesktopTests/SkinCatalogTests.swift), [shared panel tokens](../Sources/LunletDesktop/PanelStyle.swift), [Session rows](../Sources/LunletDesktop/SessionPanel.swift), [Restore](../Sources/LunletDesktop/SessionListHeader.swift), [account card](../Sources/LunletDesktop/AccountUsageSummary.swift), [allowance bar](../Sources/LunletDesktop/WeeklyAllowanceBar.swift), [usage](../Sources/LunletDesktop/UsageHistoryPanel.swift), [trend](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [panel](../Sources/LunletDesktop/CompanionPanel.swift), [Panel material](../Sources/LunletDesktop/PanelMaterial.swift), [Settings](../Sources/LunletDesktop/PreferencesPane.swift), [status and age](../Tests/LunletDesktopTests/PanelStyleTests.swift), [entry](../Tests/LunletDesktopTests/VineEntryTests.swift), [trend geometry](../Tests/LunletDesktopTests/WeeklyQuotaTrendTests.swift), [three-row fit](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [keyboard](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [window](../Sources/LunletDesktop/PanelPlacement.swift), [segmented control](../Sources/LunletDesktop/PanelSegmentedControl.swift), [surface](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [placement and page budget](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [segmented control](../Tests/LunletDesktopTests/PanelSegmentedControlTests.swift), [Claude](../Sources/LunletDesktop/ProviderSummaries.swift), [Claude](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [render of every page](../Tests/LunletDesktopTests/PanelPageRenderTests.swift).

Design note: system text styles with nothing below 10 pt and a 4-point spacing scale; status symbols with labels (attention orange, running blue, green only for confirmed success); the expanded panel flush with the top screen edge with concave shoulders, its header in the notch band and plain system material without custom gradients or haze; a black task cue continuing the notch; deeper entry lettering on light menu bars; an orange waiting badge; allowance bars with the 20/40/60/80 and 10% warning marks and no minor ticks; Swift Charts for the usage and trend charts.

Design note: the panel uses translucent frosted glass — Liquid Glass where available (macOS 26 and later) with a vibrant behind-window material fallback, and opaque bordered surfaces under Reduce Transparency or Increase Contrast — with smooth spring transitions; every segmented switch (provider tabs and Active/History) uses one segmented style, an elevated sliding selection pill that looks identical whether or not the panel is key, in a regular and a small size. The black task-cue island stays opaque (AC-13.08).

Design note: panel pages use four text roles — title 13 pt semibold, primary 13 pt, secondary 11 pt in the secondary color and a 15 pt semibold figure only for the Overview totals and the Codex remaining percentage — with one size per line and monospaced digits; a 4-point grid with 12 pt card padding and section gaps, rows 6 apart and groups 8, so card text, segmented labels and session rows share one leading edge; and one 8 pt meter for every allowance and plan-limit bar. The page budget stays fixed so switching tabs never resizes the panel; each page's last element fills it instead of leaving blank space.

### US-21: Choose a menu-bar entry instead of the notch widget

Status: Confirmed.

Product page: #yours.

**As a developer, I want to choose a standard right-side macOS menu-bar entry instead of the notch widget, so that I can use Lunlet in the presentation mode I prefer.**

Acceptance criteria:

- **AC-21.01**: **Given** appearance settings, **When** I choose menu-bar mode, **Then** the notch widget is hidden and a standard macOS menu-bar entry opens the Lunlet details panel.
- **AC-21.02**: **Given** menu-bar mode, **When** its entry is visible, **Then** it uses a monochrome template version of the lun·let lettering shown beside the notch, tinted by the system like other menu-bar items on light, dark and tinted menu bars, with any waiting count as plain text beside it; it does not use the full-color application icon, the simplified crescent or a system moon symbol.
- **AC-21.03**: **Given** either presentation mode, **When** Lunlet is running, **Then** only one application entry is shown; switching back to notch mode retains the existing no-notch fallback behavior.

Implementation: [Entry controller](../Sources/LunletDesktop/NotchEntryController.swift), [menu artwork](../Sources/LunletDesktop/MenuBarController.swift), [Native regressions](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [a regression](../Tests/LunletDesktopTests/LunletWordmarkTests.swift).

### US-19: Select supported coding agents and see a combined overview

Status: Confirmed.

Product page: #glance.

**As a developer, I want to choose which supported coding agents appear in Settings, so that I can monitor my selected tools together without unrelated providers cluttering the interface.**

Acceptance criteria:

- **AC-19.01**: **Given** provider settings, **When** I choose which supported agents to display, **Then** I can select implemented providers individually. Codex and Claude Code are first-release providers; Settings lists only implemented providers, and a later agent such as Cursor appears only once its interfaces and acceptance gates are satisfied.
- **AC-19.02**: **Given** exactly one selected provider, **When** I open Lunlet, **Then** its provider page is shown without requiring an Overview navigation step.
- **AC-19.03**: **Given** more than one selected provider, **When** I open Lunlet, **Then** an Overview summarizes the selected providers and separate provider pages retain their detailed information.
- **AC-19.04**: **Given** different provider interfaces, **When** information is displayed, **Then** unavailable fields remain unknown and provider-specific limits are not combined into an invented common allowance.
- **AC-19.05**: **Given** more than one selected provider, **When** I view the panel, **Then** a horizontal tab bar, leading-aligned with the page content so later providers append to the right, lists Overview followed by each selected provider; Overview is selected by default and each tab keeps its own page. Overview has no navigation of its own and shares the provider pages' frame, so switching tabs never moves a section: a Limits card of the provider cards' height with one row per selected agent window — Codex weekly, Claude Code session and weekly — each a compact line with the agent's color dot, name, window and its own reset time over its own meter, with percent left (never combined); then, where provider pages switch Active and History, a cost or tokens switch with today's and the selected range's combined recorded totals in that metric (tokens by default, the other metric on hover; the switch reads Tokens then Cost); then, in the session list's place, a daily chart for that range with one bar per day stacked by agent in each agent's AC-16.03 color, a line joining each day's total at the top center of its bar, a dashed daily-average line labeled at its trailing end, per-day detail on hover and a legend naming each agent's total for the shown days. Values are labeled as lower-bound estimates. It shows no session list; each provider tab shows that provider's full detail. With exactly one selected provider no tab bar is shown (AC-19.02).

Provider compatibility, discovery, usage sources, continuation capabilities, and overview aggregation require separate feasibility validation. Display selection alone does not prove integration readiness. The first release covers Codex and Claude Code phase A (US-33); Claude phone replies and Cursor remain later work.

Implementation: [Settings](../Sources/LunletDesktop/PreferencesPane.swift), [provider preference](../Sources/LunletDesktop/PreferencesStore.swift), [panel](../Sources/LunletDesktop/CompanionPanel.swift), [Overview](../Sources/LunletDesktop/ProviderSummaries.swift), [observation owner](../Sources/LunletDesktop/SessionObservationModel.swift), [provider pages](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [multi-source owner](../Tests/LunletDesktopTests/SessionObservationModelTests.swift).

### US-26: Keep customization stable across upgrades

Status: Confirmed.

**As a developer, I want validated preferences to survive updates, so that changing styles, providers, or channels does not force me to rebuild my setup.**

- **AC-26.01**: **Given** preferences from a supported prior version, **When** Lunlet updates, **Then** valid selections are retained or explicitly migrated, and an unsupported style does not prevent opening Settings.
- **AC-26.02**: **Given** invalid saved preferences or an invalid imported skin, **When** validation fails, **Then** Lunlet explains the invalid setting and retains a usable last-known configuration; credentials remain in Lunlet's user-only credential file rather than non-secret preferences, exports or skin files.

This is a confirmed supporting requirement for US-16 through US-21. Resolve a small versioned configuration format, defaults/reset behavior, validation, and compatibility policy alongside those features, not as an unrelated framework.

Implementation: [Versioned preferences](../Sources/LunletDesktop/PreferencesStore.swift), [Tests](../Tests/LunletDesktopTests/PreferencesStoreTests.swift).

## EPIC-06: Keep control of access and application reliability

Outcome: Stop remote access, recover faults and use the app accessibly without exposing private data or leaving background control behind.

### US-12: Stop mobile access and disconnect

Status: Confirmed.

**As a developer, I want to stop mobile continuation and disconnect Feishu, so that I remain in control of remote access to my local sessions.**

Acceptance criteria:

AC-12.01 through AC-12.03 require revocation and fresh-control behavior for full continuation. They do not introduce an Away Mode switch; its activation interaction remains the open decision above.

- **AC-12.01**: **Given** Away Mode is on, **When** I turn it off, **Then** new mobile input is rejected, Feishu notifications stop, and all previously issued mobile controls become invalid while local session monitoring remains available.
- **AC-12.02**: **Given** Feishu is connected, **When** I disable remote input or disconnect the integration, **Then** affected cards can no longer submit actions.
- **AC-12.03**: **Given** mobile access is enabled again after Away Mode was turned off, remote input was disabled, or Feishu was disconnected, **When** continuation becomes available, **Then** only fresh controls targeting revalidated current sessions and requests can submit actions; earlier controls remain invalid.
- **AC-12.04**: **Given** Lunlet is running, **When** I quit it, **Then** its remote-control connections, owned background operations, and sleep-prevention request are released, its windows and menu-bar entry are removed, and the process exits without leaving unexplained background control.
- **AC-12.05**: **Given** Lunlet is running, **When** I want to stop it, **Then** an explicit Quit action is accessible without scrolling in the panel's Settings page and from its entry context menu; dismissing the panel alone does not quit the application.

Implementation: [setup model](../Sources/LunletDesktop/FeishuSetupModel.swift), [recovery tests](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [owner-message client](../Sources/LunletFeishu/BotClient.swift), [transport tests](../Tests/LunletFeishuTests/BotClientTests.swift), [sleep resource](../Sources/LunletDesktop/IdleSleepAssertion.swift).

The [gate](../Sources/LunletCore/ContinuationGate.swift) and [tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) also invalidate old controls across access changes and require fresh session observations before issuing replacements. The [router and its tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) apply the same boundary to issued forms and delivered message bindings, while preserving controls when access is unchanged. The [socket lifetime tests](../Tests/LunletFeishuTests/FeishuSocketTests.swift) also verify cancellation of an idle native receive and connection-specific invalidation without revoking a replacement connection. The [application runtime](../Sources/LunletDesktop/CompanionRuntime.swift) owns cleanup, and the [application delegate](../Sources/LunletApp/LunletApp.swift) delays termination until cleanup finishes. [Away model tests](../Tests/LunletDesktopTests/AwayModeModelTests.swift) cover overlapping toggles and quit with synthetic resources. The fixed Settings footer and entry context menu expose Quit. Actual pointer interaction and complete live connection shutdown remain unaccepted; process-level quit verification is recorded in feasibility.

### US-14: Diagnose problems without exposing private data

Status: Confirmed. Logging scope: local macOS unified logging plus one bounded local error file (AC-14.07), without diagnostic reports.

**As a developer, I want basic local logs for important operations and failures, so that I can locate problems without exposing my credentials or conversations.**

Acceptance criteria:

- **AC-14.01**: **Given** Lunlet starts, connects, receives or rejects an action, calls Codex, retries, or shuts down, **When** an important diagnostic event occurs, **Then** the macOS system log identifies its component, operation, outcome, and safe error category or code; received, submitted, processing, failed, and uncertain remain distinct.
- **AC-14.02**: **Given** an operation has multiple stages, **When** those stages are logged, **Then** an opaque identifier generated for that diagnostic operation connects them without logging original account, session, request, or message identifiers.
- **AC-14.03**: **Given** logging is active, **When** an event is recorded, **Then** a fixed metadata allowlist excludes credentials, authorization links, signed endpoint tickets, raw HTTP/RPC bodies, provider error text, subprocess output, conversations, prompts, replies, file contents, and identifying filesystem paths.
- **AC-14.06**: **Given** normal operations or error recovery, **When** diagnostics are recorded, **Then** logging adds no network request, and its only application-managed storage is the bounded error file of AC-14.07, does not change authorization or retry decisions, and does not display additional alerts; basic viewing instructions are documented for Console or the system log command.
- **AC-14.07**: **Given** Lunlet runs as the app, **When** a failed or uncertain event is recorded, **Then** the same allowlisted metadata is also appended, off the main thread, to a private local file at `~/Library/Logs/Lunlet/lunlet.log` that rotates at 256 KB keeping one previous file, so it never exceeds about 512 KB; it holds no other events, is never uploaded, and Settings › About can show it in Finder. Tests and tools never write it.

Deferred scope, with IDs reserved for later confirmation: `AC-14.04` (custom storage, retention controls, and clearing) and `AC-14.05` (in-app report preparation and export). These are not active acceptance criteria and must not be referenced by first-release code. macOS manages log retention; Lunlet does not automatically upload diagnostics.

Implementation: [typed system logger](../Sources/LunletCore/DiagnosticLog.swift), [opt-in native test](../Tests/LunletCoreTests/DiagnosticLogTests.swift), [continuation receipts](../Sources/LunletCore/ContinuationGate.swift), [Feishu transport](../Sources/LunletFeishu/FeishuConnectionRunner.swift), [Keychain operations](../Sources/LunletFeishu/EnrollmentStore.swift), [Codex account reads](../Sources/LunletCodex/CodexAccountClient.swift), [app lifecycle](../Sources/LunletApp/LunletApp.swift), [power resource](../Sources/LunletDesktop/IdleSleepAssertion.swift), [Viewing instructions](../README.md#development).

### US-24: Use the panel comfortably with a keyboard and assistive tools

Status: Confirmed.

**As a developer, I want keyboard access and readable state cues, so that I can use Lunlet without relying on precise hovering or color perception.**

- **AC-24.01**: **Given** the panel and its auxiliary chart or connection card, **When** I navigate by keyboard, **Then** focus follows a predictable order and controls can be operated and dismissed without a pointer trap.
- **AC-24.02**: **Given** quota warnings or connection states, **When** color is unavailable or difficult to distinguish, **Then** labels, symbols, and accessibility values still convey the state.
- **AC-24.03**: **Given** the pinned panel has keyboard focus, **When** I press Command-R or Command-comma, **Then** it performs the same global Refresh or opens Settings as the header buttons, without stealing focus from other applications when the panel is not key.

Suggestion extends existing accessibility behavior under US-03 and US-04. Evaluate an optional configurable open-panel shortcut, chart focus behavior, and VoiceOver together; do not add global keyboard interception without a separately reviewed design.

Implementation: [panel header](../Sources/LunletDesktop/CompanionPanel.swift), [native check](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [Weekly allowance](../Sources/LunletDesktop/AccountUsageSummary.swift), [The auxiliary controller](../Sources/LunletDesktop/UsageHoverPanelController.swift), [Native tests](../Tests/LunletDesktopTests/UsageHoverPanelTests.swift).

### US-25: Keep monitoring lightweight as history and session counts grow

Status: Confirmed.

**As a developer, I want Lunlet to remain responsive and economical in the background, so that monitoring does not slow coding work or unnecessarily consume battery.**

- **AC-25.01**: **Given** representative idle, active, and large-history workloads, **When** performance is evaluated, **Then** CPU, memory, disk reads, wakeups, and panel-open latency are measured against recorded budgets before optimization is accepted.
- **AC-25.02**: **Given** cached usage or overlapping refresh requests, **When** refresh completes or fails, **Then** independent sections expose unavailable or incomplete results without fabricating zero usage or blocking unrelated data unnecessarily. The account update label describes the account read; the history hover chart does not repeat an update time.

The current observer has a five-second discovery sweep and bounded readers; usage refresh can still scan local history. Investigate incremental accounting, reusable metadata, bounded retention, and refresh ownership after measurement. Budgets are recorded in the measurement evidence below; further cache changes require a measured need. Do not prebuild a generic provider platform.

Implementation: [Opt-in performance probe](../Tests/LunletDesktopTests/PerformanceBudgetTests.swift), [range-cancellation regressions](../Tests/LunletDesktopTests/LocalUsageModelTests.swift), [Local accounting](../Sources/LunletDesktop/LocalUsageModel.swift), [The chart](../Sources/LunletDesktop/UsageHistoryPanel.swift).

## EPIC-07: Publish and support a trustworthy product

Outcome: Understand the product, obtain a verifiable release and its usage terms, and optionally support maintenance.

### US-28: Understand Lunlet through a product landing page

Status: Confirmed.

Product page: #film.

**As a prospective user, I want a polished single-page product introduction hosted through GitHub, so that I can understand Lunlet and see how it works before downloading it.**

- **AC-28.01**: **Given** the product page, **When** I visit it, **Then** it presents the selected Lunlet identity, core benefits, supported capabilities, installation requirements, and a download link to the corresponding GitHub Release.
- **AC-28.02**: **Given** an interaction illustration or demonstration video, **When** it explains the notch, usage, or mobile workflow, **Then** it uses sanitized demonstration content and clearly distinguishes shipped behavior from planned features; product pictures are renders of the real interface with synthetic data, regenerated by script rather than captured from a screen.
- **AC-28.03**: **Given** the free hosting constraint, **When** the page is published, **Then** its hosting and repository visibility are explicitly chosen to fit GitHub Free, and the page remains readable on desktop/mobile and with reduced motion.
- **AC-28.04**: **Given** the first public source preview, **When** someone opens the README or product page, **Then** a captioned, click-to-play product video uses only synthetic content to explain local observation, usage, locked completion notices and one reply that continues the same session; it never autoplays or implies unaccepted transport behavior, and it shows the real app's notch entry, panel and motion rather than slides. Until such a film exists, the README shows synthetic screenshots of the real interface.

Implementation: [Product page source](../website/index.html), [native-asset builder](../scripts/build_site.py), [configuration tests](../scripts/test_site.py), [manual Pages workflow](../.github/workflows/pages.yml), [film render](../Tests/LunletDesktopTests/ProductFilmRenderTests.swift), [script](../scripts/render-film.sh), [MP4](../website/video/lunlet-walkthrough.mp4), [captions](../website/video/lunlet-captions.vtt), [poster](../website/video/lunlet-poster.jpg), [film scenery](../Tests/LunletDesktopTests/ProductFilmScenery.swift), [still render](../Tests/LunletDesktopTests/SiteAssetRenderTests.swift), [still script](../scripts/render-site-assets.sh), [render manifest check](../scripts/check_site_assets.py), [page publication workflow](../.github/workflows/pages.yml).

### US-27: Download a versioned macOS release from GitHub

Status: Confirmed. Owner decision 2026-11-01: the first downloadable release is an unsigned preview package, an ad hoc-signed ZIP with first-open and update notes, because Developer ID signing and notarization require a paid Apple Developer Program membership the owner has not taken; a signed, notarized release remains the later path. The download is a disk image with the app beside an Applications link; the ZIP packaged with it serves the update feed.

Product page: #availability.

**As a developer, I want a clearly versioned Lunlet download on GitHub, so that I can install and update it without compiling the source myself.**

- **AC-27.01**: **Given** an owner-approved release, **When** I open its GitHub Release, **Then** I can find the macOS download, release notes, minimum OS and architecture requirements, and artifact checksums for the matching source tag.
- **AC-27.02**: **Given** the owner's GitHub Free cost constraint, **When** release automation is designed, **Then** it uses a documented free-compatible path with explicit repository visibility, runner, storage, and budget assumptions; it does not silently require a paid service.
- **AC-27.03**: **Given** a distribution candidate, **When** it is prepared for publication, **Then** automated checks, clean packaging, credential continuity, signing/notarization status, and clean-machine install/update results are reviewed before publication. Development previews are not presented as public releases, and an unsigned preview package is never presented as signed or notarized.
- **AC-27.04**: **Given** an owner-approved public source preview before any downloadable package exists, **When** the repository becomes public, **Then** the README, product page and release status label it as source-only, omit a binary download, identify unaccepted messaging and continuation behavior, and retain a separate path to a later GitHub Release.
- **AC-27.05**: **Given** an unsigned preview release, **When** I read its GitHub Release or the product page, **Then** both say that macOS asks to allow the app on first open and name the steps (System Settings › Privacy & Security › Open Anyway on macOS 15 and later; right-click › Open before that), and never call it notarized; an update asks for nothing, because credentials live in Lunlet's user-only file rather than the Keychain (AC-01.02); the packaged manifest records ad hoc signing and no notarization, and a signed, notarized release later replaces these notes.

Implementation: [README source-preview status](../README.md), [manual validation workflow](../.github/workflows/validate.yml), [candidate packager](../scripts/package-release.sh) with its unsigned preview mode, [application build](../scripts/build-app.sh), [release guide](releases.md), [product page availability copy](../website/index.html), [release boundary tests](../scripts/test_release.py).

### US-29: Understand the project's license and third-party provenance

Status: Confirmed.

**As a user or contributor, I want clear license, copyright, and third-party attribution information, so that I can understand the terms for using and contributing to Lunlet.**

- **AC-29.01**: **Given** the first public release, **When** the repository and package are prepared, **Then** the owner-approved project license, actual copyright holder, and open-source description are consistent and available; free-of-charge distribution is not treated as a substitute for license review.
- **AC-29.02**: **Given** tracked files, **When** licensing metadata is added, **Then** project-owned source has the chosen license identifier and approved copyright marking in an appropriate header. Generated or reused files retain upstream notices; formats that cannot accept comments, including binary artwork, receive appropriate external licensing metadata rather than corrupting files or claiming upstream ownership.
- **AC-29.03**: **Given** dependencies, generated code, artwork, fonts, and product references, **When** release review occurs, **Then** an inventory records origin, version, license, modifications/reuse, required notices, and unresolved permissions. Required notices accompany the source and distributed package as applicable.
- **AC-29.04**: **Given** a competing product used as inspiration, **When** acknowledgments are written, **Then** they distinguish conceptual reference from copied or adapted material and do not imply endorsement. A thank-you does not replace required authorization or notices.
- **AC-29.05**: **Given** Settings › About, **When** I open it, **Then** it shows the lun·let lettering with the version and build, a one-line description, the developer (yukunlabs), the open-source license (0BSD, free for everyone), a short privacy summary (runs on this Mac with no analytics, credentials in Keychain, notices only to the channel I set up), bundled third-party software with its license, and the copyright line, all on one page of the panel without scrolling. It shows no link to an unpublished repository.

Implementation: [The provenance inventory](../NOTICE.md), [0BSD LICENSE](../LICENSE), [The traceability check](../scripts/check_traceability.py), [tested](../scripts/test_traceability.py), [About page](../Sources/LunletDesktop/PreferencesPane.swift).

### US-30: Optionally support project maintenance

Status: Confirmed.

**As a user who values Lunlet, I want an optional way to support its maintenance, so that I can contribute financially without changing access to its free functionality.**

- **AC-30.01**: **Given** an owner-approved support link, **When** I view the repository or product page, **Then** an unobtrusive secondary link labeled "Buy me a coffee" lets me voluntarily open an external support page, without a prominent fundraising block, payment prompt in the coding workflow, or feature paywall.
- **AC-30.02**: **Given** no selected donation provider or recipient account, **When** Lunlet is published, **Then** support remains optional and no placeholder payment destination, financial commitment, or unverified eligibility claim is published.

- **AC-30.03**: **Given** the support entry, **When** I have not followed its link, **Then** the product page and repository do not display collection QR codes, payment-account details, or a list of payment methods. Those details, if used, belong on the linked support page.
- **AC-30.04**: **Given** approved support destinations for mainland China and overseas supporters, **When** I open the optional support page, **Then** each offered route leads to a verified recipient and supported checkout method; unavailable routes, placeholder accounts and unapproved crypto addresses are not published.

Implementation: [product page](../website/index.html), [Configuration tests](../scripts/test_site.py).

### US-34: Contribute through a clear review process

Status: Confirmed. The first public source release precedes a signed macOS package. Depends on US-27 for repository publication, US-29 for licensing and provenance, and the story approval rules for application changes.

**As a contributor, I want clear issue and pull request requirements, so that I can propose a useful change and know how it will be reviewed.**

- **AC-34.01**: **Given** a public repository, **When** I open an Issue, **Then** bug and feature forms ask for reproducible behavior or a user outcome, supported versions and sanitized evidence as relevant, and direct security reports to a private channel rather than a public Issue.
- **AC-34.02**: **Given** a pull request, **When** I submit it for review, **Then** the template asks for the confirmed story and criterion IDs, affected behavior, focused tests and manual acceptance gaps, privacy and third-party material checks, and release-document impact; unconfirmed behavior is not merged as an implementation detail.
- **AC-34.03**: **Given** the public default branch, **When** a contribution is merged, **Then** the repository requires its validation check and resolved review conversations, disallows force pushes and deletions, and has a maintainer review policy that works with one maintainer; adding a mandatory independent approval waits until another reviewer is available.

Implementation: [contribution guide](../CONTRIBUTING.md), [bug](../.github/ISSUE_TEMPLATE/bug.yml), [feature](../.github/ISSUE_TEMPLATE/feature.yml), [Issue configuration](../.github/ISSUE_TEMPLATE/config.yml), [PR template](../.github/pull_request_template.md).

### US-35: Learn about and install updates

Status: Confirmed. Sparkle 2 with automatic checks and installation only after a click. Depends on US-27 for published releases and their destinations, and on US-29 for third-party notices.

**As a Lunlet user, I want to learn that a new version is available and install it with one click, so that I stay current without visiting a website or reinstalling by hand.**

- **AC-35.01**: **Given** a release build with a configured update feed, **When** Lunlet starts and about once a day while it runs, **Then** it checks the feed in the background, sending only what the update framework needs (the app and macOS versions), and when a newer version exists it shows a small notice in the panel footer without interrupting work; nothing is downloaded or installed before I act.
- **AC-35.02**: **Given** the notice or Settings › About › Check for Updates…, **When** I choose to update, **Then** I see the new version and its release notes, and installing downloads it, verifies its EdDSA update signature and, for a Developer ID-signed release, the same code signature, replaces Lunlet and relaunches it with my settings, skins and saved bot authorization intact, signed or not, because credentials live in Lunlet's user-only file (AC-01.02); a failure leaves the installed version unchanged and says so.
- **AC-35.03**: **Given** Settings › About, **When** I open it, **Then** it offers Check for Updates… and a switch for automatic checks, on by default; turning it off stops background checks, and a manual check still works.
- **AC-35.04**: **Given** a development preview or a build without a configured feed and update key, **When** it runs, **Then** it performs no update checks and shows no update controls, so a preview never offers to replace itself.

Implementation: [package manifest](../Package.swift), [license](../Resources/third-party/sparkle-license.txt), [provenance inventory](../NOTICE.md), [The updater](../Sources/LunletDesktop/AppUpdater.swift), [panel footer](../Sources/LunletDesktop/CompanionPanel.swift), [About](../Sources/LunletDesktop/PreferencesPane.swift), [Info.plist](../Resources/Info.plist), [Packaging](../scripts/build-app.sh), [Unit tests](../Tests/LunletDesktopTests/AppUpdaterTests.swift), [release tests](../scripts/test_release.py), [render harness](../Tests/LunletDesktopTests/PanelPageRenderTests.swift), [Release preparation](releases.md#updates-with-sparkle).

## Release acceptance

A public source preview precedes a downloadable package (AC-27.04), and the first package is an unsigned preview (AC-27.05). That source-only milestone is an honest, reviewable repository snapshot; it is not acceptance of the complete first-release runtime below. A downloadable macOS package and any claim that mobile continuation works retain their own gates. The product page and video may demonstrate shipped local behavior with synthetic data while naming any channel delivery or reply behavior that is not yet accepted.

The first release is ready when the stories applicable to the declared release scope pass in the recorded macOS, Codex and Claude Code versions. Confirmation alone is not acceptance; Cursor, Claude phone replies and optional support do not become first-release gates. Record the reference terminal environments used for verification without making terminal brands a capability allowlist. Verification must cover at least two concurrent sessions, two sessions in the same project, continued context over multiple turns, local task cues with and without full-continuation access, display sleep and lock behavior, lock-screen mobile interaction, approval isolation, duplicate and stale actions, enabling full-continuation access with already-pending work, disabling and re-enabling mobile access, unavailable Feishu setup or connectivity, disconnection, session exit and restore, and quitting Lunlet. The Settings switch in AC-05.08 and AC-05.09 governs phone replies; screen locking alone does not authorize input.

Before a binary release, confirm the provenance inventory in US-29, including the icon's generation terms, and the applicable distribution decisions in US-27. The 0BSD license and copyright identity are selected; their presence does not waive that review. Source publication does not authorize a binary release, paid enrollment or support destination.

Acceptance also covers the confirmed scope expansions: CLI, Codex App, editor, execution and child-session observation; Claude Code phase A observation and usage; default and exposed custom accounting roots; same-UUID copies across roots/archives; new activity after Clear; History membership controlled by Clear; unknown state/pricing; selected one-to-seven-day Token/Cost ranges; notch/menu-bar exclusivity; and Feishu authorization/owner binding and Slack/Telegram private pairing, plus all three channels' cancellation, channel switching and uncertain-send behavior. Feishu, Telegram and Slack delivery and one reply per notice are verified live (see [feasibility](feasibility.md#messaging-channels)). Keep observation, original-app navigation, notification delivery and original-CLI input as separate acceptance results. Full mobile continuation cannot pass until the question answer path (US-07) is built and validated alongside the verified follow-up path; the Settings activation rule is already confirmed under AC-05.08 and AC-05.09.

Record reproducible steps, observed results, supported versions, and failure boundaries in [the feasibility notes](feasibility.md). The developer must be able to start work on the Mac, step away, receive useful summaries, answer an ordinary question or send a follow-up to the correct existing session, and understand the outcome without maintaining a separate agent platform.

