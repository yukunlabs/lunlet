# Product requirements

Lunlet helps an individual developer notice when coding work needs attention and continue it during short periods away from the computer. The Mac remains the primary work environment; mobile provides limited continuation of work already started there.

This document records agreed product behavior as user stories. It is a specification, not a claim that integrations have been proven. Evidence and outstanding feasibility work belong in [the feasibility notes](feasibility.md).

## Release scope

| Area | First release | Later or excluded |
|---|---|---|
| Platform | macOS | Linux later; other platforms not planned |
| Agent | Existing local Codex sessions: CLI, Codex App, editor clients, execution and child sessions with readable local records; local Claude Code sessions for observation, usage and notifications (US-33) | Claude phone replies followed the first package (US-38); Cursor and other agents later; remote-only or unpersisted sessions unavailable |
| Codex environment | Local observation independent of client or terminal product; original CLI continuation is separately gated | SSH and remote-host discovery; control of Desktop and IDE clients |
| Mobile channel | User-owned Feishu/Lark, Slack, or Telegram bots; one selected channel | Other messaging services |
| Remote actions | Answer ordinary questions; send follow-up instructions after a turn finishes | New conversations, new tasks, active-turn takeover, execution approvals, general computer control |
| Interface | Compact, notch-inspired desktop panel with an entry point on displays without a notch | A full chat client, remote desktop, team console, agent orchestration |

Observation and accounting include all observable local Codex client types. Original-app navigation requires its own verified destination. Notification delivery requires a verified event and selected owner-bound channel. Mobile answering and follow-up remain restricted to eligible original CLI sessions and their separately validated input path; observing Codex App, editor, execution or child sessions does not promise controlling them. Each channel takes one reply per completion notice that continues the same Codex session: the Feishu card's reply box, a Telegram reply or a Slack thread reply (US-08, US-36). Ordinary chat never becomes session input.

**Active sessions** in the panel are observed sessions the user has not cleared; a finished turn or process exit does not move them into History automatically. A **live CLI connection** may remain open and eligible for a follow-up even while its conversation is in History; liveness and list placement are separate facts. A **finished turn** may still leave the original task unfinished. An **ended session** has exited and is no longer eligible for mobile continuation. A stored or loaded thread alone does not prove that a terminal session is active.

## Epics and user journey

These Epics group existing confirmed stories by user outcome. Stories retain their stable IDs even though they are now ordered by journey rather than creation date. A story has one primary Epic; dependencies do not create duplicate ownership.

| Epic | User outcome | Stories |
|---|---|---|
| EPIC-01 | Stay aware of current Codex work | US-02, US-03, US-13, US-15, US-23, US-33 |
| EPIC-02 | Understand allowance and recorded usage | US-04, US-18, US-32, US-37, US-41 |
| EPIC-03 | Connect one private channel and receive useful updates | US-01, US-20, US-22, US-05, US-06 |
| EPIC-04 | Continue the correct existing CLI conversation safely | US-07, US-08, US-09, US-10, US-11, US-36, US-38 |
| EPIC-05 | Personalize a focused and durable macOS interface | US-31, US-16, US-17, US-21, US-19, US-26, US-39, US-40, US-42 |
| EPIC-06 | Keep control of access and application reliability | US-12, US-14, US-24, US-25 |
| EPIC-07 | Publish and support a trustworthy product | US-28, US-27, US-29, US-30, US-34, US-35 |

The everyday journey is:

1. Launch Lunlet and begin existing work on the Mac. EPIC-01 automatically discovers observable sessions; EPIC-02 shows account quota and local recorded usage. Neither depends on connecting a messenger.
2. Inspect work locally. Start and input cues identify sessions; sessions enter History only when the user clears them. Clear hides Active entries locally, new verified work restores them, and an identifiable original destination may be reopened. History has no separate clear action.
3. Optionally choose and connect one messaging channel. EPIC-03 distinguishes authorization, private recipient binding, delivery, callback reception and session-input readiness. A saved credential does not imply a usable return path.
4. Lock the Mac. Newly verified completions are delivered automatically under AC-05.06; startup/recovery snapshots are not replayed as new completions. Unlocking, disconnecting or quitting stops this notification path; the only switch is phone replies in Settings (AC-05.08).
5. For the full continuation target, answer the exact pending ordinary-question card or submit a follow-up from its completion card. EPIC-04 requires verified original-CLI identity and lifecycle, EPIC-03 owner/callback readiness and EPIC-06 revocation safeguards. It preserves context and permissions, provides an accurate receipt, and never turns arbitrary chat or an execution approval into input.
6. On exit, interruption, restart, channel changes or return to the Mac, revalidate capabilities and invalidate stale controls. Recover the affected stage without clearing unrelated local work; Quit releases owned operations and power assertions.

EPIC-05 enhances this journey without making unsupported providers operational. EPIC-07 applies before public publication; optional support never gates the coding workflow. EPIC-06 safeguards apply across every other Epic.

## Delivery status

Approval, release scope, delivery and acceptance are separate facts. A story's Status line records approval and dependencies; this table, in Epic order, is the one place that records what is delivered and which acceptance gate remains; feasibility notes carry the reproducible evidence. A listed gate never marks a story complete.

| Story | Current runtime delivery | Remaining gate |
|---|---|---|
| US-02 | Wired local discovery and compact status | Question/approval classification and original App/VS Code device acceptance |
| US-03 | Wired local inspection and destination gates | Physical notch/hover/display and original-host navigation acceptance |
| US-13 | Wired start/input/completion cues and suppression; the Needs you cue with its optional sound (synthetic) | Owner visual and multi-display/full-screen acceptance; a live Claude Code wait with the cue and the sound |
| US-15 | Wired Active/History, source-recency ordering and Clear | Original-device list lifecycle acceptance |
| US-33 | Phase A: registry and transcript observation, recorded usage, locked completion notifications; status-line weekly limit, account email and plan from Claude Code's local profile, tokens-first usage; synthetic evidence plus live status-line readings | Owner-assisted live Claude session, usage, locked delivery and footer checks |
| US-23 | Wired identifiable Active/History without search/filter, with source-reported relative ages | Final large-list owner evaluation |
| US-04 | Wired account/local usage, estimates, Settings explanation and the five-hour line | Source-specific account and physical presentation acceptance, including the five-hour line on a real read |
| US-18 | Wired persisted one-to-seven-day charts | Automated/native checks exist; final owner evaluation |
| US-32 | Range forecast from full-resolution readings, even-pace line and stale, too-early and exhausted states | Live predicted-versus-observed accuracy over a real week and packaged-app review |
| US-37 | Not started | Deferred until Claude Code's public interface reports the data; no credential, cookie or screen-scraping route |
| US-41 | Wired rule, notifier, Notification Center delivery and Settings › Usage controls (synthetic) | Notification permission and delivery from the preview bundle verified on device |
| US-01 | Scan-based setup of a new or existing app, owner-bound delivery and callback reception, verified live | Feishu card review in the phone app |
| US-20 | Three-channel notification selection and private binding; Telegram and Slack pairing and locked delivery verified live | None |
| US-22 | Wired factual readiness in Settings and the attached card for every channel, and explicit credential recovery | None |
| US-05 | Automatic locked completion delivery; Codex completion cards carry a reply box during the unlock-ended reply window (AC-05.09), verified live | The Settings switch (AC-05.08) and initial-state controls (AC-05.02) |
| US-06 | Completed-turn notices with the request excerpt and the agent's final reply on all three channels; the Feishu card and the Telegram and Slack notices verified live | Feishu card review in the phone app; question, approval and failure classifications |
| US-07 | Card-only callback ingress for completion-card follow-ups, verified live on a scan-created app; answering questions unavailable | Question provenance and an original-CLI answer path |
| US-08 | Gated `codex queue` follow-up path from the completion card's reply box: live-binding recheck, delivery confirmed from the session record, session-named receipts; verified live | Live refusal paths and broader device acceptance |
| US-09 | Follow-ups refused while a turn runs or waits for approval; queued input keeps the session's policy, verified live | Live execution-approval challenge through the mobile path |
| US-10 | Received, submitted, confirmed, unconfirmed, failed and refused receipts with at-most-once dispatch; in-place card updates verified live | Timeout and reconnect journey |
| US-11 | Exited, reused-PID, restored and reconnected sessions refuse before queueing (synthetic) | Live callback/input recovery and network-loss acceptance |
| US-36 | Slack and Telegram notices take one reply that continues the same Codex session, with the notice rewritten in place; both verified live | None |
| US-38 | Stop hook added with the Claude Code switch, bundled helper, held turns while locked, replies through the hook with transcript confirmation; a phone reply reached a live Claude Code session held while the Mac was locked, on 2026-11-06 | None |
| US-31 | Wired six-category native Settings | Final physical usability acceptance |
| US-16 | Wired native RGB/hue and shared warning palette | Owner visual acceptance |
| US-17 | Wired Vine/Lantern and validated declarative skins | Physical style and imported-skin acceptance |
| US-21 | Wired exclusive notch/menu modes, full artwork and the allowance text with its Only below level | Physical lock/wake and display-transition acceptance; the text on a real menu bar |
| US-39 | Pet entry with six poses and three coats, cues routed to the dog, the panel beside it, position kept per display, hover status and accessibility label; poses rendered and checked against the sketches | On-device acceptance of the floating window across Spaces, full-screen apps and locking, and of click-through on transparent space |
| US-42 | Full-screen detection from window frames and display-sleep assertions, the three choices and their setting; a packaged preview stepped aside under a full-screen window that began to keep the display awake (macOS 27, before the entry learned to stay away through a pause and to fade) | The final behavior on screen; a browser's and a player's own full-screen video, Safari, a player that fills the display above the menu bar, an external display and macOS 14 to 26 |
| US-19 | Codex and Claude Code selectable; one provider shown directly, several with a segmented Overview of totals and parallel provider tabs | On-device tab acceptance; Cursor remains later scope |
| US-26 | Wired validated non-secret preferences and recovery | Preferences and credentials surviving a real in-app update (US-35) |
| US-12 | Wired Quit/cleanup; phone-reply switch and disconnect invalidate issued controls | Live stale-control invalidation and complete live connection shutdown |
| US-14 | Wired bounded macOS unified logging and the bounded local error file | On-device opt-in diagnostics checks |
| US-24 | Wired chart keyboard access, panel Command-R/Command-comma, symbol-and-label states and chart descriptors | Physical VoiceOver and full connection-card focus order |
| US-25 | Wired bounded readers and independent successful freshness | Real-discovery, uncached full-app CPU/memory/disk/wakeup/latency acceptance |
| US-28 | Product page published on GitHub Pages with the repository and latest-release download links; the support link stays hidden until its destination exists | Browser, responsive and keyboard acceptance of the published page |
| US-27 | Source published; `v0.1.0` (2026-11-01), `v0.2.0` and `v0.2.1` (2026-11-14) released as unsigned previews with checksums, manifest and notes | Clean-machine validation; Developer ID signing and notarization deferred by owner decision |
| US-29 | 0BSD license with SPDX headers, provenance inventory, packaged notices, trademark statement and About details | None for the first package: the owner confirmed the icon's provenance and the README privacy statements on 2026-11-01 |
| US-30 | Optional link omitted until an approved URL exists | Owner support destination; optional and not a coding-workflow gate |
| US-34 | Contribution guide, issue forms and PR template in place; branch protection and private vulnerability reporting are enabled at publication | First external PR acceptance |
| US-35 | Sparkle 2.10.1 wired for configured release builds: footer notice, About controls, embedded framework; installed copies updated on the maintainer's Mac, `v0.1.0` to `v0.2.0` through the feed and `v0.2.0` to `v0.2.1` in the rehearsal | The same update on a clean Mac; the update window coming forward by itself in a packaged build; Developer ID signing deferred by owner decision |

## Story approval and traceability

Every product capability must be specified by a user story and its acceptance criteria in this document before code is written. README text, technical notes, implementation plans, and code comments cannot authorize additional behavior.

- Story status is `Proposed`, `Confirmed`, `Deferred`, or `Rejected`. Only the product owner can confirm a new story or a material change to agreed behavior. Confirmation in conversation must be recorded here before implementation; an agent cannot approve its own proposal.
- A story's Status line records its approval and dependencies; release membership follows the Release scope table, not the word Confirmed; delivery and open gates are in the Delivery status table and Open items. Deferred criteria keep their reserved IDs (AC-14.04 and AC-14.05) and are never referenced by code. Cursor and other agents are later work; Claude phone replies followed the first package as US-38. Implementation evidence and on-device acceptance are separate from approval, and no approval bypasses an unresolved feasibility gate.
- Review proposed or changed stories for user value, release scope, contradictions, duplication, security boundaries, dependencies, and testable outcomes before confirming them. Record unresolved issues with the proposal and stop only the affected implementation. Design rules and algorithm details that stories rely on live in [design notes](design.md), referenced from the story; acceptance criteria state observable outcomes.
- For a proposed revision, retain the confirmed behavior and record the proposed changes and affected criterion IDs separately until the product owner confirms them. Do not overwrite the implementation baseline with an unconfirmed revision.
- Every code change, including experiments, tests, refactoring, and supporting infrastructure, must identify the confirmed story IDs and acceptance-criterion IDs it serves. Supporting work must explain the connection; it must not introduce unrelated behavior or invent a technical user story to bypass this rule.
- Plans, source headers, and test references must map implementation and verification to those IDs. When implementation starts, maintain an `Implementation evidence` entry under each affected story linking source entry points, tests, and verification results. Evidence must be updated when behavior, code locations, or criteria change.
- Missing, unknown, unconfirmed, or contradictory requirements block the affected code change. Referencing an ID alone is insufficient: review must check that the actual behavior and verification match the cited criteria. Follow-up requirements changes must assess linked code and tests before implementation resumes.
- Each story belongs to exactly one outcome-based Epic; shared dependencies link to the owning story rather than duplicating its behavior. Epic grouping does not authorize new functionality. Keep story IDs and acceptance-criterion IDs stable. Do not renumber or reuse them when reordering or retiring requirements. Record replacements explicitly so existing code and test references remain understandable.
- Product page linkage: a story the product page presents declares `Product page: #section`. The site build refuses a page section that presents a story that is not `Confirmed`, and refuses to build while a confirmed story's declared section does not present it; the page's facts (agents, messengers, skins, macOS target) are read from the sources, and its pictures carry a manifest of the sources they were rendered from (`scripts/check_site_assets.py`). A story therefore reaches the page in the same change that confirms it, or the build says what is missing.
- Feedback intake: record new owner feedback as TODOs by default rather than immediately investigating or implementing it. Bugs are priority 1; new features are priority 2. Priority orders the backlog, not permission to start. Resume the selected work when the owner explicitly requests execution; keep first-release publication gates separate from feature scheduling.

## Proposed Codex setup constraint

Status: Proposed, not accepted. A launch-path integration (a one-time Codex setup that instruments later CLI sessions) was considered before `codex queue` gave a terminal-independent path to the original CLI; it would now be considered only for capabilities that path cannot offer, as an explicit, removable opt-in whose mechanism and undo path need confirmation first. It would change the compatibility boundary of AC-02.01, AC-02.04, AC-08.01 and AC-11.04 and is not authorized by any implementation detail.

## Open items

Work that is not finished or not yet accepted. Confirmed behavior not listed here is implemented and covered by tests; per-story gates are in the Delivery status table and in [feasibility](feasibility.md). Decisions already taken are recorded in [release preparation](releases.md).

Pending on-device acceptance:

- Live acceptance pending: the desktop pet across Spaces, over full-screen apps, while locked and its click-through on transparent space (US-39); Feishu cards in the phone app (US-06); the execution-approval challenge through the mobile path (US-09); original VS Code and Codex App acceptance of integrated-terminal discovery (US-02); physical lock, wake and display-transition recovery of the notch entry (US-03, US-21); the two-cord lantern skin on the device (US-17).
- Release gates: a real update from `v0.1.0` to `v0.2.0` installed on a clean Mac (US-35; it installed on the maintainer's Mac, as the feasibility notes record), which also confirms that the saved bot connection survives the update without a prompt (US-26, AC-27.05); Developer ID signing and notarization are deferred by the owner's decision of 2026-11-01 to ship an unsigned preview first (AC-27.05); the remaining branding review before a binary release (US-29); an approved support destination (US-30).

Bugs:

- TODO (bug, priority 1, not reproduced): on 2026-11-13 four notices sent from a locked Mac carried no reply box: for three the callback connection opened and no reply control was issued, and for one none was attempted. On 2026-11-14 the same path worked on a locked Mac over Feishu for a Claude Code session and for a Codex session: the notice arrived with its reply box, and one reply reached the session and was confirmed. The two card events rejected as malformed that day were not replies: the provider also delivers an event that is not a card action when the chat is opened; such an event is now acknowledged and ignored. The system log names the refusing check by number (`replyControl` and `cardAction` for the Feishu card, `stopVerdict` for a Claude Code turn), so a recurrence identifies its cause. (US-05 / AC-05.09, US-08, US-38 / AC-38.02; `log show --predicate 'subsystem == "com.lunlet"'`).
- TODO (bug, priority 1, mitigated): Quit stalled twice on 2026-11-01 while a Slack reply listener was active; the system log holds each quit's `shutdown started` without stages or completion. Both stalls ran a build that predates the fix that resumes a Socket Mode receive on cancellation, and every later quit completed within 100 ms, so that receive is the probable cause but is unproven. Since then each shutdown stage waits at most two seconds and logs `uncertain`/`timeout` with its number, and the eight-second watchdog remains. Acceptance needs one owner reproduction: Slack selected, a Codex turn finishing while the Mac is locked, then unlock and quit within ten minutes; a clean quit with all nine stages logged closes this item (US-12 / AC-12.04, US-14 / AC-14.01; evidence in [feasibility](feasibility.md#messaging-channels)).

Not started:

- Question and approval classification (US-02 / AC-02.03, AC-02.05): pending ordinary questions and execution approvals are not yet classified from session records; no such state is inferred until they are. Not started.
- Phone-reply switch and initial-state cards (US-05 / AC-05.08, AC-05.02): the Settings switch that allows phone replies and the cards for sessions already waiting or idle when delivery begins are not built; replies currently follow the locked-Mac window and card lifetime alone. Not started.
- Answering a session's question from the phone (US-07 / AC-07.01 through AC-07.05, US-09 / AC-09.01): question cards, question provenance, the original-CLI answer path and the approval notice that points back to the Mac are not built; the completion-card follow-up (US-08) is the only live input path. Not started.
- Claude limit resets, per-model weekly shares and usage credits (US-37): deferred; see the story for the reason. Not started.

Implemented on 2026-11-12, pending on-device acceptance:

- The allowance text in the menu-bar entry (US-21 / AC-21.04, AC-21.05), allowance notifications (US-41), the Needs you cue and its sound (US-13 / AC-13.10, AC-13.11; the Codex half waits for the question and approval classification above), the pet's Failed pose with the failed row and the Petdex link (US-39, US-40) and the five-hour line (US-04 / AC-04.15) are built and covered by synthetic tests; a review of the preview and the notification permission prompt on the device remain.

Fixed on 2026-11-12, pending on-device acceptance:

- The pet's place after a drag longer than half a second, its return to framing after another Space or a full-screen app, and its Settings item (US-39 / AC-39.02, AC-39.05, AC-39.08); a Claude Code turn held and answered from the phone through the guarded hook command (US-38 / AC-38.01 through AC-38.03); a Slack or Telegram reply after a network loss while a notice is open (US-36 / AC-36.02). Each is covered by synthetic tests; evidence and what was measured are in [feasibility](feasibility.md#performance-and-resources).

Implemented on 2026-11-13, pending on-device acceptance:

- The sky header with one body per agent, the Overview and the agent pages, the session list's three-card viewport, the floating chart's words, the regrouped Settings and the dark frosted surface (US-19 / AC-19.09 through AC-19.11, US-04 / AC-04.16 through AC-04.18, US-32 / AC-32.09, US-24 / AC-24.04, US-31, US-03 / AC-03.05) are built and covered by synthetic tests, offscreen renders and captures of the real glass through the product's own surface view in a test window. Not yet checked on the device: how the move and the sky's streak feel, the chart opening from the figures row, Left and Right in the pinned panel, VoiceOver, and the idle cost of the open panel (US-25). The layout for more than four agents is not built, since the two implemented agents never reach it.
- The Codex limit of an account without a weekly window (US-04 / AC-04.19, with AC-04.01, AC-04.13, AC-04.15, AC-04.16, AC-21.04, AC-32.01, AC-32.05 and AC-41.03): the header, the entry's strand, the menu-bar text, the trend with its forecast and the allowance notifications take the account's own limit window and name it by its length. Covered by synthetic tests on the shape of a 30-day response read from a live account and an offscreen render of the 30-day chart; not yet seen on the device with such an account, and the forecast's thresholds are still those tuned for a seven-day window.

Open questions:

- Open question: whether a card's reply window should end only when the Mac unlocks, rather than after ten minutes while it stays locked (AC-05.09).

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
- **AC-02.06**: **Given** monitoring is active, **When** there is no new activity requiring attention, **Then** Lunlet remains quiet without stealing focus, repeatedly notifying, or unnecessarily expanding the panel (its background cost is bounded under US-25).
- **AC-02.07**: **Given** local Codex work, **When** I start Lunlet, **Then** session monitoring starts automatically without installing hooks, requesting hook trust, changing my Codex launch command or rewriting unrelated Codex configuration; observed activity alone never grants remote input.

- **AC-02.08**: **Given** local Codex processes holding valid session records, **When** Lunlet discovers sessions, **Then** client labels, noninteractive launch modes, Desktop originators, structured child-agent sources, and unknown or future source labels do not exclude read-only observation. Each verified session UUID appears once; stored records alone never prove current activity, and ambiguous ownership remains unverified (AC-02.05).

Implementation: [reader](../Sources/LunletCodex/CodexSessionReader.swift), [process reader](../Sources/LunletCodex/CodexProcessReader.swift), [monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [Shared accounting roots](../Sources/LunletCodex/CodexAccountingCatalog.swift), [usage reader](../Sources/LunletCodex/LocalUsageHistory.swift), [session list model](../Sources/LunletDesktop/SessionListModel.swift), [native views](../Sources/LunletDesktop/SessionPanel.swift), [presentation tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [desktop stream owner](../Sources/LunletDesktop/SessionObservationModel.swift), [Reader tests](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [monitor tests](../Tests/LunletCodexTests/CodexSessionMonitorTests.swift), [desktop integration tests](../Tests/LunletDesktopTests/SessionObservationModelTests.swift), [Both compact entries](../Sources/LunletDesktop/MenuBarController.swift), [Native entry tests](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [process reader](../Tests/LunletCodexTests/CodexProcessReaderTests.swift), [oversized-record prefix](../Sources/LunletCodex/RolloutRecordPrefix.swift).

### US-03: Inspect a session, return to its terminal and use the notch entry

Status: Confirmed. AC-03.01 through AC-03.03 cover inspection and return; AC-03.04 through AC-03.11 cover the entry beside the notch and the panel it opens, which every other story's surface depends on (presentation rules in [design notes](design.md#panel-presentation)).

**As a developer, I want to inspect a session's recent activity, return to its terminal, and reach all of it from a compact entry at the notch, so that I can understand what needs attention and continue working with minimal window switching.**

Acceptance criteria:

- **AC-03.01**: **Given** monitored sessions, **When** I expand the panel and select one, **Then** I can identify it and inspect its confirmed current activity, recent public output or summary, and latest result.
- **AC-03.02**: **Given** a supported, identifiable terminal destination, **When** I double-click its session row, **Then** Lunlet reveals the original application and corresponding existing session destination, without a separate return button or a fallback to the default Terminal application.
- **AC-03.03**: **Given** the destination cannot be located reliably, **When** I request the return action, **Then** Lunlet explains that the destination is unavailable without guessing; session observation and mobile continuation remain available when their own eligibility checks pass.
- **AC-03.04**: **Given** a display without a hardware notch, **When** I use Lunlet, **Then** I still have an accessible entry point to the session panel.
- **AC-03.05**: **Given** I open the desktop panel, **When** it expands, **Then** it is centered on the physical notch at the display's top edge, or below the menu bar on a display without a notch, rather than attached to the menu-bar icon; it remains within the screen area.
- **AC-03.06**: **Given** I opened the panel manually, **When** I close it, press Escape, or move focus to another application, **Then** the panel dismisses while Lunlet remains available from its selected notch or menu-bar entry; opening it again preserves current application state.

- **AC-03.07**: **Given** an unlocked display with a hardware notch and notch presentation selected, **When** Lunlet is running, **Then** a compact, connected lun / let lettering entry flanks the actual notch with the selected skin's allowance strand along its lower edge (US-17), using display geometry without enlarging or covering the hardware notch; both words react together to hover and task cues. Only one application entry is shown: the menu-bar fallback appears only when the notch-side entry is unavailable. Temporary lock, sleep, or unsettled display state hides the surface without selecting menu-bar mode; an available notched display recovers after the transition.
- **AC-03.08**: **Given** the compact entry, **When** I hover briefly, **Then** a non-activating session preview expands beneath the notch; the preview remains open while the pointer is inside either the entry or the expanded panel, regardless of event ordering between those regions. Leaving both regions dismisses it after a short grace period; returning during that delay or retraction keeps it expanded. Clicking the entry or interacting with the preview keeps it open until explicitly dismissed or focus moves to another application. Every click inside the open panel's outline, including empty glass between and around its modules, stays with the panel and never reaches the application beneath.
- **AC-03.09**: **Given** the session panel, **When** I inspect it, **Then** with one agent selected its page shows weekly remaining allowance and active sessions together without an Overview tab (US-19 adds the Overview for several agents), detailed usage opens from the allowance card, application preferences live in Settings, and connection setup opens from the compact footer entry (AC-20.02). Global Refresh and a Settings gear sit at the upper right; Quit is in Settings, not on the page (AC-12.05). Escape and outside-click dismissal close the panel without a Close button. Unavailable capabilities are labeled unavailable, never hidden.

- **AC-03.10**: **Given** display changes, sleep, locking, or quitting, **When** the desktop surface updates, **Then** owned entry windows and animations follow the available display and are hidden or removed appropriately. Reduce Motion disables decorative motion, and Reduce Transparency uses an opaque readable surface.
- **AC-03.11**: **Given** a hardware notch, **When** the panel opens or closes, **Then** the resting silhouette matches the current display's system-reported notch exclusion area without fixed outward padding or an idle frosted rectangle; task cues (AC-13.08) and the panel expand from that same silhouette rather than dropping a separate card below it, the lettering stays synchronized, and reopening during retraction cancels the pending close. Displays without a notch retain a simple panel.

Implementation: [Session labels](../Sources/LunletDesktop/SessionOrdering.swift), [Superset bindings](../Sources/LunletCodex/SupersetSessionBindingReader.swift), [monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [device-adaptive vectors](../Sources/LunletDesktop/VineGeometry.swift), [native entry and coordinated animation](../Sources/LunletDesktop/LettermarkView.swift), [focused regressions](../Tests/LunletDesktopTests/VineEntryTests.swift), [shared palette](../Sources/LunletDesktop/AllowancePalette.swift), [application](../Sources/LunletApp/LunletApp.swift), [notch entry](../Sources/LunletDesktop/NotchEntryController.swift), [compact native panel](../Sources/LunletDesktop/CompanionPanel.swift), [attached surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [silhouette tests](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [panel controller](../Sources/LunletDesktop/CompanionPanelController.swift), [Geometry tests](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [native interaction tests](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [entry lifecycle tests](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [optional destination reader](../Sources/LunletCodex/CodexDestinationReader.swift), [explicit host opener](../Sources/LunletDesktop/SessionDestinationOpener.swift), [monitor regressions](../Tests/LunletCodexTests/CodexSessionMonitorTests.swift), [list regressions](../Tests/LunletDesktopTests/SessionListModelTests.swift), [binding tests](../Tests/LunletCodexTests/SupersetSessionBindingReaderTests.swift).

### US-13: Notice task starts and completions locally

Status: Confirmed.

Product page: #island.

**As a developer, I want brief task-start and task-completion cues in the notch-inspired panel while I am using my Mac, so that I can notice activity without switching terminals.**

A task event here refers to a Codex turn, not each tool call or shell command. Finishing a turn does not mean that the whole task is complete or that the session has ended.

Acceptance criteria:

- **AC-13.01**: **Given** Lunlet is running and the display is on and unlocked, **When** a monitored session starts or finishes a confirmed turn, **Then** the panel briefly shows the project or session identity and the start or completion state, including success or failure only when confirmed, whether or not a messaging channel is connected.
- **AC-13.02**: **Given** a transient cue is visible, **When** its presentation timeout expires, **Then** the panel returns to its prior presentation without taking keyboard focus or activating another application; a panel I opened manually remains open.
- **AC-13.03**: **Given** the display is asleep or the Mac is locked, **When** task events arrive, **Then** Lunlet updates session state without showing these transient cues or waking the display; returning to the Mac shows current state without replaying cues for those events.
- **AC-13.04**: **Given** a session is newly discovered or monitoring reconnects, **When** existing state or a duplicate event is received, **Then** Lunlet updates the session without presenting an old transition as a new task start or completion.
- **AC-13.05**: **Given** several sessions change state close together, **When** cues are presented, **Then** the newest event immediately replaces the current cue and shows the correct session with evidence-backed state; an accumulated count does not replace session content.
- **AC-13.06**: **Given** a display without a hardware notch, **When** an eligible task event occurs, **Then** the equivalent desktop panel provides the same transient cue.
- **AC-13.07**: **Given** a notch-side entry and an eligible task cue, **When** the cue appears, **Then** the island cue of AC-13.08 appears at the notch and retracts automatically, including after new input within the same turn; the lettering can react without taking focus. Concurrent events remain attributed and accessible in the session panel.
- **AC-13.08**: **Given** an eligible start or finish cue, **When** it appears, **Then** a high-contrast island continuous with the notch extends below it and shows a bold status (Started, Completed, Stopped, Failed or Finished) with its symbol, the project, and the bounded local prompt preview, for about five seconds; it slides in and out, without motion when Reduce Motion is on (AC-03.10). Desktop panels without a notch show the same content.
- **AC-13.09**: **Given** a task cue was shown, **When** I open the panel by hover, click or keyboard while it shows or within 15 seconds after it hides, **Then** the panel shows that cue's agent tab with the cue's conversation selected, in Active or History wherever it now is; with cues from several conversations the newest wins, and an opening without a recent cue keeps the page last shown.
- **AC-13.10**: **Given** the display is on and unlocked, **When** a verified session enters a waiting state, a question for me or an execution approval on the Mac (AC-02.03, AC-33.03), **Then** the island, or the pet in pet mode, shows a Needs you cue in the attention tone with the project, Question or Approval and the bounded prompt preview, for the AC-13.08 duration, and the resting entry keeps the waiting count until the session leaves that state; a waiting state already present when Lunlet discovered the session, or a replayed record, shows no cue (AC-13.04); while the Mac is locked the phone path applies instead (US-05) and no cue is replayed on return (AC-13.03). Today only Claude Code sessions report waiting states; Codex sessions join when the question and approval classification of the US-02 open item exists.
- **AC-13.11**: **Given** Settings › Appearance, **When** I turn on Sound for Needs you (off by default), **Then** one short system sound plays with each Needs you cue and never with a start or finish cue, at the system alert volume, and nothing plays while the display is locked or asleep; the choice survives upgrades (US-26).

Implementation: [cue presentation core](../Sources/LunletCore/CuePresentation.swift), [cue behavior tests](../Tests/LunletCoreTests/CuePresentationTests.swift), [session model](../Sources/LunletDesktop/SessionListModel.swift), [non-activating native overlay](../Sources/LunletDesktop/TransientCuePanel.swift), [Desktop model tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [Measured cue text](../Sources/LunletDesktop/TaskCueText.swift), [geometry regressions](../Tests/LunletDesktopTests/TaskCueTextTests.swift), [Needs you cue and sound tests](../Tests/LunletDesktopTests/NeedsYouCueTests.swift), [cue router with the sound](../Sources/LunletDesktop/PetEntryController.swift), [OS state reads](../Sources/LunletDesktop/DisplayState.swift), [cue surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [surface](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [placement tests](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [panel check](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift).

For AC-13.09, the [session model tests](../Tests/LunletDesktopTests/SessionListModelTests.swift) check that a recent cue opens the correct provider and conversation once, while a later opening keeps the prior selection.

Revisions: 2026-11-12, AC-13.10 (the Needs you cue) and AC-13.11 (its optional sound) confirmed.

### US-15: Organize the visible session list

Status: Confirmed.

**As a developer, I want to clear conversations from Lunlet's active list without deleting them, so that I can keep the panel focused and return to those conversations when needed.**

Acceptance criteria:

- **AC-15.01**: **Given** displayed Active sessions, **When** I clear the list, **Then** Lunlet moves them into its local history view without deleting Codex conversations, ending sessions, altering remote permissions, or stopping observation.
- **AC-15.02**: **Given** a session in local history, **When** new input or a running/waiting activity is verified, **Then** it reappears in Active, including additional input during the same turn. A finished turn or ended session does not move into History automatically. Duplicate observations, metadata-only changes, and recovery without new input/turn identity do not undo clearing.
- **AC-15.03**: **Given** cleared or ended sessions, **When** I open history, **Then** I can inspect the available bounded session summary and explicitly restore ongoing work that I cleared; cleared completed sessions remain in History until new activity appears. Ended sessions remain ineligible for remote continuation. History is local presentation of observed snapshots, not a claim to import Codex's full conversation archive.
- **AC-15.04**: **Given** monitoring is unverified, **When** history or active sessions render, **Then** their uncertainty remains visible; clearing does not turn unknown state into verified state or erase ended-connection safeguards.

- **AC-15.05**: **Given** I cleared conversations into local history, **When** I explicitly refresh the overview, **Then** Lunlet rechecks the session source and restores confirmed ongoing/waiting work to Active. Completed, ended, unavailable, or ambiguously bound conversations remain in History; background recovery alone does not undo clearing.

- **AC-15.06**: **Given** local History entries, **When** I view them, **Then** entries with known observed activity are ordered most recent first, with stable session identity for ties and no fabricated recency for unavailable activity. History has no separate clear action.

Design note: rows prefer a short on-device preview of the latest user message and fall back to the session identifier; previews never enter logs, and only the owner's own completion notice carries an excerpt (AC-06.02). Sessions without identifiable content, a navigation destination and confirmed activity are not shown yet but remain observed; displayed sessions are retained during temporary monitoring interruptions; sessions with unknown relationships are never merged by project name. Codex's marked runtime-context records (environment context, injected AGENTS.md instructions and a user message wrapped entirely in one matching tag pair) are not user input: they never restore cleared sessions, set input pending, emit Started cues or become previews. No retention count, expiry rule or automatic deletion exists.

Implementation: [list model](../Sources/LunletDesktop/SessionListModel.swift), [active/history views](../Sources/LunletDesktop/SessionPanel.swift), [lifecycle tests](../Tests/LunletDesktopTests/SessionListModelTests.swift), [Reader/monitor regressions](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [ordering/lifecycle tests](../Tests/LunletDesktopTests/SessionOrderingTests.swift).

### US-33: See Claude Code sessions alongside Codex

Status: Confirmed. First-release phase A: local session observation, recorded usage, locked completion notifications and the weekly plan limit through a reversible status-line connection. Claude phone replies are US-38 (Confirmed); limit resets, per-model shares and usage credits are US-37. Depends on EPIC-02 for usage presentation, EPIC-03 for notification delivery and US-19 for provider selection and Overview.

Product page: #glance.

**As a developer who uses both Codex and Claude Code, I want Lunlet to observe my local Claude Code sessions alongside Codex, so that I can follow both agents and their recorded usage in one panel and be notified when either finishes while I am away.**

Acceptance criteria:

- **AC-33.01**: **Given** running local Claude Code sessions, **When** Lunlet observes them, **Then** each appears with its project or directory, session identity or title, the Claude agent label, state and latest activity, bound through Claude's per-process session record to a same-user live process with a matching start time and an exact session UUID and transcript, without hooks, settings changes or terminal-specific adapters.
- **AC-33.02**: **Given** two Claude sessions in one directory, or one session resumed in two processes, **When** either changes state, **Then** updates are attributed to the exact session; a session with more than one owning process stays ambiguous and observation-only.
- **AC-33.03**: **Given** recorded turn completion or a recorded wait for permission or input on the Mac, **When** Lunlet presents the session, **Then** it shows finished or waiting state from that evidence; unknown record types, versions or stale process records show unknown state rather than invented status.
- **AC-33.04**: **Given** recorded Claude usage, **When** I inspect usage, **Then** tokens are counted once per message across main and subagent transcripts, labeled as recorded usage on this Mac with API list-price cost estimates and a lower-bound note; Claude plan limits are shown as unknown until they are connected under AC-33.08, and any window without a reading stays unknown.
- **AC-33.05**: **Given** saved owner authorization and a confirmed locked Mac, **When** a verified Claude turn completes after the discovery baseline, **Then** the existing notification path delivers a bounded completion summary identifying Claude and the session, without replaying earlier work; a Claude notice carries reply controls only under AC-38.02.
- **AC-33.06**: **Given** Claude subagent transcripts, **When** they are observed, **Then** their usage counts under the parent session, and they are not listed as separate conversations and produce no separate cues.
- **AC-33.07**: **Given** Claude's local records, **When** Lunlet reads them, **Then** it reads only allowlisted metadata and usage fields, the bounded local preview permitted for Codex sessions and, for the completion notice (AC-06.02), the bounded text blocks of the reply that ends a turn; it keeps no thinking, tool use or tool results, never reads prompt history, tool-result or memory files, credentials, peer keys or environment values, and never connects to Claude's sockets.
- **AC-33.08**: **Given** Claude Code is a selected agent and Lunlet's status line is not connected, **When** Lunlet starts or Claude Code becomes selected, **Then** Lunlet connects its status line automatically unless I disconnected it before or Claude Code's existing status line is not a command or was changed outside Lunlet; the card says "Status line added" with Undo for that panel visit, and there is no separate switch: turning Claude Code off in Settings › Agents restores the previous configuration exactly and turning it on connects again; the agent switch's help explains that a custom status line hides most of Claude Code's footer keyboard hints, and Settings › Agents shows a note only for an unusual state. The card's Undo restores the previous configuration and keeps it off across launches until its Add status line button.
- **AC-33.09**: **Given** Claude rate-limit readings, **When** I view the Claude page, **Then** the weekly window is shown as percent left (100% minus the reported percent used), in the same terms as the Codex allowance, with its reset time and the reading's age; a missing window, an account without this limit or no reading shows unknown; the weekly window uses the forecast semantics of AC-32.05 through AC-32.08; Claude limits are never combined with Codex allowances, and estimates name no verdict such as "On track".
- **AC-33.10**: **Given** recorded Claude usage, **When** it is shown on the Claude page, **Then** tokens lead, as for Codex, with the API-price estimate beside them on the card and in rows, and input, output, cache-write and cache-read tokens listed separately in the card's, rows' and chart's help, so a total dominated by cache reads can be read apart. Every Tokens/Cost switch, on the Overview and in both agents' usage charts, reads Tokens then Cost and opens on Tokens, because a subscriber watches usage before its API-price equivalent.
- **AC-33.11**: **Given** Claude Code signed in on this Mac, **When** I view the Claude page, **Then** its account line matches the Codex page's (AC-04.17): the account email and plan (such as Max 20x) as Claude Code caches them in its own configuration file, then the reading's age or the connection state; Lunlet reads only those two fields of that file's `oauthAccount`, never a credential, keeps them in memory, logs neither and sends them nowhere; an unknown or unrecognized value reads as unknown, never a guess.
- **AC-33.12**: **Given** the connected status line, **When** Claude Code runs it, **Then** it keeps only the weekly window's percent used and reset time, with the time observed, in a Lunlet-owned file; it discards every other field of Claude Code's input, reads no credentials, chains any status line it replaced, and prints a compact line such as "7d 41% · resets 6d8h" after that line's output.
- **AC-33.13**: **Given** the Claude card, **When** it is laid out, **Then** it follows the Codex card's rhythm and height: the remaining figure, the meter in the same height and palette gradient as the Codex allowance, colored by what remains so the low-allowance colors of AC-04.10 apply to both agents, a reset line with the countdown and the reset's weekday and time, and a footnote with today's recorded tokens and their estimate, so switching tabs never shifts the page; the reading's age uses the Codex card's wording, such as "Updated 3m ago"; the card's chart button and hover open Claude's weekly trend in remaining terms with the AC-32.06 estimate above daily usage on this Mac, as Codex's does.

Revisions: 2026-11-06, Claude Code stopped reporting a five-hour window (Claude's own usage page shows only the weekly limit with per-model shares), so the five-hour session window left AC-33.08 and AC-33.09 and is no longer read, stored or shown; the Claude card took the Codex card's layout (AC-33.13) and its footnote's token categories moved into help (AC-33.10); per-model shares and usage credits are US-37. 2026-11-06, US-38 added reply controls to the notices of Claude turns held by Lunlet's Stop hook (AC-33.05). 2026-11-13, with the panel redesign the Claude page's account line follows AC-04.17 and the provider cards, with their Limits titles (AC-33.11), are gone.

Implementation: [registry reader](../Sources/LunletClaude/ClaudeSessionRegistry.swift), [process check](../Sources/LunletClaude/ClaudeProcessReader.swift), [transcript locator](../Sources/LunletClaude/ClaudeProjects.swift), [transcript reader](../Sources/LunletClaude/ClaudeTranscriptReader.swift), [monitor](../Sources/LunletClaude/ClaudeSessionMonitor.swift), [usage reader](../Sources/LunletClaude/ClaudeLocalUsageReader.swift), [price table](../Sources/LunletClaude/ClaudePricing.swift), [Claude page](../Sources/LunletDesktop/ProviderSummaries.swift), [provider](../Sources/LunletCore/SessionObserving.swift), [Feishu](../Sources/LunletFeishu/SessionCard.swift), [locked notification owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [registry and process](../Tests/LunletClaudeTests/ClaudeSessionRegistryTests.swift), [transcript](../Tests/LunletClaudeTests/ClaudeTranscriptReaderTests.swift), [monitor](../Tests/LunletClaudeTests/ClaudeSessionMonitorTests.swift), [usage](../Tests/LunletClaudeTests/ClaudeLocalUsageReaderTests.swift), [multi-source desktop owner](../Tests/LunletDesktopTests/SessionObservationModelTests.swift), [provider pages](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [notifications](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [card](../Tests/LunletFeishuTests/SessionCardTests.swift), [notice](../Tests/LunletCoreTests/SessionNoticeTests.swift), [Claude Code plan limits section](../Sources/LunletDesktop/ClaudePlanLimitsSettings.swift), [connection](../Sources/LunletClaude/ClaudeStatusLineConnection.swift), [in-place document edit](../Sources/LunletClaude/ClaudeSettingsDocument.swift), [status-line command](../Sources/LunletClaude/ClaudeStatusLineScript.swift), [reader](../Sources/LunletClaude/ClaudePlanLimitsReader.swift), [window readings](../Sources/LunletCore/AccountLimits.swift), [wording](../Sources/LunletDesktop/ClaudeLimitsPresentation.swift), [model](../Sources/LunletDesktop/ClaudePlanLimitsModel.swift), [categories](../Sources/LunletCore/LocalUsage.swift), [script](../Tests/LunletClaudeTests/ClaudeStatusLineScriptTests.swift), [connection](../Tests/LunletClaudeTests/ClaudeStatusLineConnectionTests.swift), [reader](../Tests/LunletClaudeTests/ClaudePlanLimitsReaderTests.swift), [presentation, forecast and model](../Tests/LunletDesktopTests/ClaudeLimitsPresentationTests.swift), [limits group](../Sources/LunletDesktop/PanelStyle.swift), [shared trend chart](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [agent colors](../Sources/LunletDesktop/AllowancePalette.swift), [Codex fit](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [panel heights](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [header labels](../Sources/LunletDesktop/HeaderPresentation.swift), [profile reader](../Sources/LunletClaude/ClaudeAccountProfile.swift), [Tests](../Tests/LunletClaudeTests/ClaudeAccountProfileTests.swift), [settings editor](../Sources/LunletClaude/ClaudeSettingsEditor.swift), [concurrent settings edits](../Tests/LunletClaudeTests/ClaudeSettingsEditsTests.swift).

### US-23: Find the right session in a large list

Status: Confirmed.

**As a developer with many sessions, I want clearly separated active work and local history with identifiable conversations, so that I can quickly inspect the correct conversation.**

Acceptance criteria:

- **AC-23.01**: **Given** many observed conversations, **When** I switch between Active and History, **Then** sessions remain identifiable even when projects or titles are identical, without a search or state-filter control.
- **AC-23.02**: **Given** either session view, **When** new input or completion arrives, **Then** the ordering of AC-15.06 keeps session identity, Clear semantics and the destination of a mobile card unchanged.
- **AC-23.03**: **Given** a session row with source-reported activity time, **When** I scan the list, **Then** it shows a compact relative age such as "2m"; unavailable activity time shows no age rather than an invented one.

Implementation: [Presentation ordering](../Sources/LunletDesktop/SessionOrdering.swift), [The session header](../Sources/LunletDesktop/SessionListHeader.swift), [Regressions](../Tests/LunletDesktopTests/SessionOrderingTests.swift), [rows](../Sources/LunletDesktop/SessionPanel.swift), [Tests](../Tests/LunletDesktopTests/PanelStyleTests.swift).

## EPIC-02: Understand allowance and recorded usage

Outcome: Judge remaining account allowance and local consumption using reported values and clearly qualified estimates.

### US-04: Understand account limits and session usage

Status: Confirmed.

Product page: #limits.

**As a developer, I want to see trustworthy limits and usage with their source and freshness, so that I can judge whether my work can continue.**

Acceptance criteria:

- **AC-04.01**: **Given** the source provides account quota windows, **When** I inspect limits, **Then** Lunlet shows the supported remaining allowance, reset time, source and freshness separately from session state. The reset line shows a countdown to the hour and the reset's weekday and time (a time alone when it is today; its month, day and time when it is more than six days away, where a weekday no longer tells the day), the same wording on every card, row and chart; an elapsed reset reads due, without assuming that quota has refreshed.
- **AC-04.02**: **Given** session token or cost information is available, **When** it is displayed, **Then** account quota, session usage, actual billing, and token-based cost estimates are clearly distinguished. Each session row shows recorded tokens and equivalent estimated USD together, without a metric toggle; missing token categories, model prices, or usage records remain unavailable. Where only part of the usage can be priced, a known subtotal may be shown with explicit price coverage; the full cost remains unknown. Visible session amounts use compact monetary precision while help retains the precise estimate and coverage.
- **AC-04.03**: **Given** a value is unavailable or a refresh fails, **When** the panel renders, **Then** an unknown or stale value is identified as such and is not replaced with zero.
- **AC-04.04**: **Given** Lunlet starts with a local Codex sign-in, **When** it reads account usage automatically, **Then** no user enable/stop switch is required; settings briefly explains the source, purpose, and request destination in a low-emphasis footer, with credential-handling detail in hover help rather than a dedicated explanation block. Credentials are not exposed or forwarded through Feishu. Quitting cancels owned reads.
- **AC-04.05**: **Given** limits are being monitored, **When** Lunlet schedules refreshes, **Then** it avoids unnecessary frequent polling and repeated notifications; its refresh rate is bounded under US-25.
- **AC-04.06**: **Given** the official account interface provides available earned-reset entitlements, **When** I inspect usage, **Then** Lunlet shows the reported count and any supplied expiration details separately from remaining allowance; missing count or details remain unknown, and Lunlet does not infer an unannounced global reset or redeem an entitlement.
- **AC-04.07**: Replaced by AC-04.16 on 2026-11-13. It described a compact progress bar for the seven-day window above the session list; the window is still identified by its reported duration, never by its primary or secondary position, and missing weekly data stays unavailable rather than borrowing another window.
- **AC-04.08**: **Given** trustworthy per-day usage records, **When** I inspect daily usage, **Then** hovering over the usage block opens a separate floating chart beside the panel, without clicking or navigating away, for the range chosen under US-18, with Token and Cost switching. Moving into the chart keeps both it and the panel open; leaving the anchor and chart dismisses it after a short grace period. Token counts come from that agent's local usage records; cost is an estimate at published API list prices, not a subscription bill. Local history is labeled This Mac, separate from account quota and other devices. Missing records or prices remain unavailable. Daily consumption is never fabricated by subtracting rolling quota snapshots.

- **AC-04.09**: **Given** the account interface supplies identity, plan, or credit balance, **When** I inspect usage, **Then** the account email or supplied username and reported plan appear on the account line (AC-04.17); the Credits balance uses grouping and at most two decimal places with tiny nonzero values visibly nonzero, and the AC-04.06 reset entitlements appear beside it as passive text: the count and the next expiry, with every date in hover details, with no refresh-style icon or click action. Missing fields stay unknown; plan multipliers and currency are not inferred.
- **AC-04.10**: **Given** a reported weekly allowance and the vine skin, **When** I inspect its remaining-progress bar, **Then** both the outer vine and expanded straight bar share the same remaining value, gradient palette, proportional marks at 20%, 40%, 60%, and 80%, and the red 10% low-allowance mark; the panel itself draws no allowance bar (AC-04.16). Colors transition continuously from the default blue-purple or the selected normal tint under US-16 toward yellow below 20% and toward deeper red below 10%. Unknown data does not display a remaining fill. No exhaustion forecast or daily-consumption claim is implied.
- **AC-04.11**: **Given** locally recorded usage from any Codex client or task source, **When** Lunlet aggregates usage, **Then** tokens and estimated costs include those records regardless of source label, deduplicate copies of the same session across discovered accounting roots and archives, and preserve unknown pricing and incomplete-coverage distinctions. Account quota remains separate from this Mac's recorded usage.
- **AC-04.12**: **Given** an account, usage or connection value is unavailable after a failed read, **When** it is shown, **Then** it stays unknown and states that Refresh can try again, without automatic retries or polling.
- **AC-04.13**: **Given** the vine skin with both agents selected, **When** the compact entry is shown, **Then** two intertwined strands replace the single outer vine: one shows the remaining allowance of Codex's limit window (AC-04.19) and the other Claude Code's weekly remaining (100% minus the seven-day percent used), each in its AC-16.03 color with the shared 20/40/60/80 marks and 10% warning, and each keeps its own unknown state. The two are never combined into one value. With one agent selected the single vine shows that agent. The lantern skin's two-agent form is AC-17.09.
- **AC-04.14**: **Given** the Codex page, **When** I look for freshness, **Then** a compact relative Updated label describes the last successful account read; opening the panel or a failed refresh does not reset it; a global Refresh in the outer header next to Settings covers account information, local usage history and connected session sources without changing the view or clearing sessions, and concurrent refreshes are prevented.
- **AC-04.15**: **Given** Codex reports a five-hour window beside its limit window (AC-04.19), identified by its reported duration of 300 minutes rather than by its primary or secondary position, **When** I open the Codex page, **Then** its figures row (AC-04.17) reads "5-hour window" with its percent left and its reset in the AC-04.01 wording, never combined with the limit window; the vine, the lanterns, the header and the forecast keep the limit window. A successful read that reports no five-hour window leaves the figure out, since that account has none, and the row's help says so; only the absence of any successful read shows it as unknown (AC-04.03). Claude Code reports no such window (US-33 revision of 2026-11-06), so the Claude page shows none. The window counts among those AC-21.04 and US-41 may report.
- **AC-04.16**: **Given** an agent's page, **When** I read the header, **Then** the percent left of the agent's limit window (AC-04.19 for Codex, the weekly window for Claude Code) is the figure under the agent's body, with the window named by its length and its reset in the AC-04.01 wording; the figure follows the warning colors of AC-04.10 below 20% and 10%; the panel draws no allowance bar. The Overview shortens the reset to its countdown. The entry's strand keeps AC-04.10 and AC-04.13.
- **AC-04.17**: **Given** an agent's page, **When** I read below the header, **Then** one account line shows the email or username and the plan and, at its trailing end, the Updated age of the last successful read (AC-04.14) or the one action the state calls for (Refresh after a failed read, the status-line states of AC-33.08); a figures row beneath it lists only what that agent reports: the five-hour window with percent left and reset (AC-04.15), Credits and reset entitlements (AC-04.09), and today's recorded tokens with their estimated cost on one line. A value that could not be read says Unknown. There are no provider cards.
- **AC-04.18**: **Given** an agent's page, **When** I rest the pointer on the figures row, focus it and press Return or Space, or press Command-U, **Then** the floating chart of AC-04.08 opens beside the panel; no chart button is shown.
- **AC-04.19**: **Given** a successful Codex account read, **When** Lunlet shows the account's limit, **Then** the limit is the account's weekly window when it reports one and otherwise its longest reported window of a day or more, such as the 30-day window of a plan without a weekly one; the window is chosen by its reported duration, never by its primary or secondary position, among several buckets the default Codex bucket's is taken, and two such windows that cannot be told apart give none. The window is named by its length (Week, Month, or a count of days) wherever it appears: the header (AC-04.16), the entry's strand (AC-04.13), the menu-bar text (AC-21.04), the trend and its forecast (US-32) and the allowance notifications (US-41). The five-hour window is never the limit, and a read that reports no window of a day or more shows the limit as unknown rather than borrowing another window (AC-04.03).

Implementation: [typed quota values](../Sources/LunletCore/AccountLimits.swift), [Codex quota decoding](../Sources/LunletCodex/AccountLimitsDecoder.swift), [decoder tests](../Tests/LunletCodexTests/AccountLimitsDecoderTests.swift), [bounded read-only Codex client](../Sources/LunletCodex/CodexAccountClient.swift), [synthetic subprocess tests](../Tests/LunletCodexTests/CodexAccountClientTests.swift), [compact weekly summary](../Sources/LunletDesktop/AccountUsageSummary.swift), [the limit window and its span](../Sources/LunletDesktop/AccountUsagePresentation.swift), [the header's Codex label](../Sources/LunletDesktop/HeaderPresentation.swift), [its tests](../Tests/LunletDesktopTests/HeaderPresentationTests.swift), [duration-based selection tests](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [presenter tests](../Tests/LunletDesktopTests/AccountUsageModelTests.swift), [local reader](../Sources/LunletCodex/LocalUsageHistory.swift), [left hover panel](../Sources/LunletDesktop/UsageHoverPanelController.swift), [Accounting tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [history model tests](../Tests/LunletDesktopTests/LocalUsageModelTests.swift), [native hover tests](../Tests/LunletDesktopTests/UsageHoverPanelTests.swift), [usage chart](../Sources/LunletDesktop/UsageHistoryPanel.swift), [trend](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [Claude card and Overview](../Sources/LunletDesktop/ProviderSummaries.swift), [session list](../Sources/LunletDesktop/SessionPanel.swift), [entry](../Sources/LunletDesktop/LettermarkView.swift), [centerline](../Sources/LunletDesktop/VineGeometry.swift), [entry controller](../Sources/LunletDesktop/NotchEntryController.swift), [runtime's](../Sources/LunletDesktop/CompanionRuntime.swift), [Entry tests](../Tests/LunletDesktopTests/VineEntryTests.swift), [controller test](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [`agentVariant`](../Sources/LunletDesktop/AllowancePalette.swift), [tested](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [header](../Sources/LunletDesktop/PanelHeader.swift), [Usage Settings](../Sources/LunletDesktop/PreferencesPane.swift), [account line and figures row](../Sources/LunletDesktop/AgentFigures.swift), [figures tests](../Tests/LunletDesktopTests/AgentFiguresTests.swift), [page width checks](../Tests/LunletDesktopTests/AgentPageLayoutTests.swift) over [the panel fixture](../Tests/LunletDesktopTests/PanelFixture.swift).

Revisions: 2026-11-12, AC-04.15 (the five-hour line) confirmed; the same day, because an account that reports only the weekly window showed a permanently unknown line, a read reporting no five-hour window leaves the line out instead. 2026-11-13, the panel redesign confirmed: AC-04.16 through AC-04.18 replace the progress bar of AC-04.07 and move the account line, the Updated label, the five-hour window, Credits and reset entitlements into the account line and figures row; AC-04.09 now shows the count and the next expiry instead of a countdown per credit, and AC-04.10 no longer describes bars in the panel. The same day an account on a plan that reports a single window of 43,200 minutes and no weekly one showed no limit, because Lunlet looked for the limit only by the weekly duration. Showing whichever long window the account reports was confirmed: AC-04.19 was added, AC-04.13, AC-04.15 and AC-04.16 now name the limit window instead of the weekly one, and AC-04.01 writes a reset more than six days away with its month and day.

### US-32: Understand weekly allowance pace

Status: Confirmed.

**As a developer, I want to compare my observed weekly allowance with an estimated consumption pace, so that I can judge whether my allowance is likely to last until reset.**

Acceptance criteria:

- **AC-32.01**: **Given** comparable official quota observations in the same limit window (the weekly window, or the longer one AC-04.19 identifies), **When** I inspect the trend, **Then** I can distinguish observed remaining allowance from an estimated future trajectory and the reset time; the chart's title names the window by its length, and a window too long to label every day is ticked in dates several days apart.
- **AC-32.02**: **Given** sufficient recent observations and a usable reset time, **When** the estimate indicates exhaustion before reset, **Then** the estimate names a projected run-out time, otherwise the estimated remaining percentage at reset, shown as AC-32.06 describes and never as a guarantee; it is recalculated as new observations arrive and when the view is opened.
- **AC-32.03**: **Given** missing, stale, sparse, conflicting or reset-crossing observations, **When** I inspect the trend, **Then** unavailable periods are not invented and an unsupported forecast is not shown.
- **AC-32.04**: **Given** the existing local Token/Cost chart, **When** weekly allowance is shown, **Then** account quota percentages remain separate from local token counts and API-price cost estimates; the charts do not imply that either local measure equals account consumption.
- **AC-32.05**: **Given** a comparable reading and a reported reset of the limit window, **When** I inspect the trend, **Then** remaining is compared with the even budget across that window's own length at that reading's time, is not labeled a forecast, stays visible when no forecast is shown, and is omitted after a detected mid-window increase.
- **AC-32.06**: **Given** a forecast, **When** it is shown, **Then** the chart draws it as a central estimate and shaded range from the latest reading and states it once in words (AC-32.09); hovering the estimate region, and VoiceOver, state the estimated range of remaining at reset or the estimated run-out time with its earliest plausible time; estimates with less than a day of current-window evidence, or that ignore the previous window, are labeled rough, and no range is presented as a guarantee.
- **AC-32.07**: **Given** the latest reading is more than one hour old, **When** the forecast is shown, **Then** it starts at that reading and states its time; a reading more than 24 hours old, a passed reset, or no successful account read identifying the window produces no forecast and states the reason, while a failed account read does not hide an estimate built from earlier same-window readings and labels it stale.
- **AC-32.08**: **Given** fewer than six hours of current-window readings and no usable earlier window, **When** I inspect the trend, **Then** it shows that it is too early to estimate; **Given** no decrease across at least a day of readings, **Then** the estimate equals the current remaining; **Given** a 0% reading, **Then** the trend shows the observed run-out and reset time rather than a projection.
- **AC-32.09**: **Given** a forecast, **When** the floating chart is shown, **Then** one line above the trend states it in words, about how much is left at reset with its range or the estimated run-out time, labeled an estimate and never a guarantee; without a forecast the line gives the AC-32.03, AC-32.07 or AC-32.08 reason instead.

Implementation: [Independent quota estimation](../Sources/LunletCore/WeeklyQuotaEstimator.swift), [local history matching](../Sources/LunletDesktop/WeeklyQuotaTrend.swift), [recorded quota extraction](../Sources/LunletCodex/LocalUsageHistory.swift), [hover chart](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [Estimator tests](../Tests/LunletDesktopTests/WeeklyQuotaTrendTests.swift), [local reader tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [synthetic panel rendering](../Tests/LunletDesktopTests/WeeklyQuotaTrendPanelTests.swift), [account model](../Sources/LunletDesktop/AccountUsageModel.swift), [Estimator tests](../Tests/LunletCoreTests/QuotaPaceEstimatorTests.swift), [stale-read model test](../Tests/LunletDesktopTests/AccountUsageModelTests.swift), [the chart's words](../Sources/LunletDesktop/TrendChartText.swift), [their tests](../Tests/LunletDesktopTests/TrendChartTextTests.swift).

The chart's drawing rules and the estimator's inputs and limits are in [design notes](design.md#weekly-trend-chart-and-pace-estimator); they bind the implementation and change only with these criteria.

Revisions: 2026-11-13, with the panel redesign, AC-32.09 was confirmed, which reverses the earlier rule of AC-32.06 that the forecast has no sentence of its own: the floating chart is now the only place the forecast appears. The same day, with AC-04.19, the trend follows the account's own limit window: AC-32.01 and AC-32.05 no longer say weekly or seven-day, the even budget and the pace are measured over the window's own length, readings of a window of another length are never comparable, and a local record is kept for its own window's lookback.

### US-18: Choose the usage history range

Status: Confirmed.

**As a developer, I want to choose in Settings how many days the usage chart displays, so that the chart shows the time range I find useful.**

Acceptance criteria:

- **AC-18.01**: **Given** usage settings, **When** I select a history range, **Then** supported values are the integers 1 through 7 inclusive, and five days (today and the previous four) is the default.
- **AC-18.02**: **Given** a selected range, **When** I open the usage chart, **Then** it displays that number of local calendar days with one bar per day, each labeled, and the weekly trend's observed span starts at that range's first day.
- **AC-18.03**: **Given** Token and Cost views, **When** I switch the chart metric, **Then** both views use the same selected date range and retain existing unknown-data and estimate distinctions.

Implementation: [The bounded reader](../Sources/LunletCodex/LocalUsageHistory.swift), [chart](../Sources/LunletDesktop/UsageHistoryPanel.swift), [Reader range tests](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [model cancellation tests](../Tests/LunletDesktopTests/LocalUsageModelTests.swift).

### US-37: See Claude's limit resets, per-model shares and usage credits

Status: Deferred, decided on 2026-11-06. Claude Code's documented interface for Lunlet, the status line, reports only the weekly window, so these values have no supported local source; the routes other tools use (Claude Code's OAuth token from its rotating Keychain item and an undocumented account endpoint, a claude.ai browser cookie, or scraping `claude`'s `/usage` screen) were examined and declined for the prompts, token conflicts and the AC-33.07 promise they would cost (evidence in [feasibility](feasibility.md#claude-code-observation)). The story waits for a documented local interface and is not a first-release gate. Depends on US-33.

**As a Claude subscriber, I want Lunlet's Claude page to show my limit resets, each model's share of the weekly limit and my usage credits, so that it tells me what Claude's own usage page tells me without opening it.**

Acceptance criteria:

- **AC-37.01**: **Given** Claude Code reports limit reset grants through a documented local interface, **When** I view the Claude page, **Then** it shows the available reset count and each grant's expiry in the Codex card's "Reset credits" wording and position, and shows unknown when the interface reports nothing.
- **AC-37.02**: **Given** Claude Code reports a per-model weekly share, **When** I view the Claude page, **Then** each reported model's percent left and its share of the weekly limit appear below the weekly window in the same meter and wording, never combined with the weekly window or with Codex.
- **AC-37.03**: **Given** Claude Code reports usage credits, **When** I view the Claude page, **Then** their state and balance appear in the Codex card's "Credits" position, labeled as reported by Claude Code, and unknown otherwise.
- **AC-37.04**: **Given** none of these values is reported, **When** I view the Claude page, **Then** nothing is invented, no credential, cookie or screen of Claude Code is read for them, and the card keeps its current rows.

Implementation: none.

### US-41: Be told when an allowance runs low or resets

Status: Confirmed. Depends on US-04 for the windows and their readings (AC-04.15 for Codex's five-hour window), US-25 for the refresh budget, US-26 for the preference and US-31 for Settings. Phone delivery of completed turns (US-05, US-06) is unchanged; this story never uses the messaging channel.

**As a developer, I want a macOS notification when an allowance window drops below a level I chose, and when it resets, so that I learn in time without opening the panel.**

Acceptance criteria:

- **AC-41.01**: **Given** Settings › Usage, **When** I look for notifications, **Then** an Allowance notifications switch is off by default; turning it on asks macOS once for notification permission, a denied or missing permission is stated beside the switch with an Open System Settings button, nothing is sent until it is granted, and turning the switch off sends nothing further.
- **AC-41.02**: **Given** the switch is on, **When** I choose when to be told, **Then** a Warn below picker offers 30%, 20%, 10% and 5% left (20% by default, the meters' yellow mark of AC-04.10) and a separate When a window resets switch is off by default; the choices survive upgrades (US-26).
- **AC-41.03**: **Given** an officially reported window Lunlet shows (Codex's limit window under AC-04.19, Codex's five-hour window under AC-04.15, Claude Code's weekly window under AC-33.09), **When** a reading puts its remaining allowance below the chosen level, **Then** one notification names the agent, the window by its length (weekly or monthly allowance, or the 5-hour window), the percent left and the reset moment in the AC-04.01 wording, and that window is not reported again until a later reading shows it above the level or reset; forecasts (US-32), unknown and stale values never notify.
- **AC-41.04**: **Given** the reset switch is on, **When** a reading taken after a window's reset moment shows it refreshed (a later reset moment, or more allowance than before), **Then** one notification says that the window has reset; an elapsed reset without such a reading sends nothing (AC-04.01).
- **AC-41.05**: **Given** notifications are on, **When** Lunlet decides whether to send one, **Then** it uses the readings it already takes (AC-04.05, US-25) and adds no polling; a notification carries the agent's name and no account identity, activating it opens the panel on that agent's page, and it is never relayed to the messaging channel.

Implementation: [readings, rule, notifier and permission note](../Sources/LunletDesktop/AllowanceNotifications.swift), [Notification Center deliverer](../Sources/LunletDesktop/AllowanceNotificationCenter.swift), [runtime wiring](../Sources/LunletDesktop/CompanionRuntime.swift), [agent page focus](../Sources/LunletDesktop/SessionListModel.swift), [panel tab](../Sources/LunletDesktop/CompanionPanel.swift), [Settings › Usage](../Sources/LunletDesktop/PreferencesPane.swift); [rule, notifier and subscription tests](../Tests/LunletDesktopTests/AllowanceNotificationsTests.swift).

Revisions: 2026-11-13, with AC-04.19, AC-41.03 reports Codex's limit window, weekly or longer, where it named the weekly one, and names it by its length; a window of another length is another window and is judged afresh.

## EPIC-03: Connect one private channel and receive useful updates

Outcome: Reach the owner through one selected messenger, with minimal setup and truthful readiness at each stage.

### US-01: Connect Feishu with minimal setup

Status: Confirmed. AC-01.02 also states the credential-storage rule every channel follows (US-20, US-36, US-26 refer to it).

Revisions: 2026-11-01, the credential file replaced the Keychain so that updates of an unsigned build never ask for authorization, and the same day the file was sealed for this Mac and user; the Keychain store remains in the code for a later signed release.

**As a developer, I want to connect my own Feishu bot by scanning and authorizing, so that I can enable mobile continuation without configuring developer infrastructure manually.**

Acceptance criteria:

- **AC-01.01**: **Given** Feishu is not connected, **When** I choose Connect Feishu, **Then** Lunlet presents the official application authorization flow with a choice of an eligible existing application or a new one; it does not force creation.
- **AC-01.02**: **Given** I scan and authorize successfully, **When** setup completes, **Then** Lunlet obtains the user-owned application's credentials, prepares the required configuration and reports connection status. Every channel's credentials are kept in Lunlet's credential file on this Mac: readable by my user account only, sealed with a key bound to this Mac and account so that a copy elsewhere cannot be opened and a backup or disk scan shows no token, never in preferences, exports or skin files, and never behind an authorization prompt, so updates ask for nothing; a process running as my user is not kept out, and Lunlet's documentation says so. A connection an earlier build saved in the Keychain, or wrote in the clear, is moved into the sealed file on first use (through one Authorize access click when that build may not read the Keychain item); a file this Mac and user cannot open is reported as such, and I can remove it and connect again.
- **AC-01.03**: **Given** a normal setup, **When** I follow the flow, **Then** I do not need to create an application in the developer console, select individual permissions, or copy secrets manually.
- **AC-01.04**: **Given** authorization is denied, expires, or is blocked by organization permissions, **When** setup cannot finish, **Then** Lunlet explains the failure and offers a recoverable next step without claiming success.
- **AC-01.05**: **Given** Feishu setup succeeds, **When** mobile access is configured, **Then** Lunlet binds it to the verified owner identity for that application and requests only necessary messaging permissions, without unrelated calendar or document access.
- **AC-01.06**: **Given** connection and privacy information is presented, **When** I review the access boundary, **Then** Lunlet explains its owner access controls and applicable organization restrictions without claiming that a user-owned bot is immune to Feishu administration.

- **AC-01.07**: **Given** I choose an existing application, **When** the official authorization page prepares configuration changes, **Then** I review and confirm them there before Lunlet accepts the returned credentials; the same verified identity and secure-storage rules apply to both existing and new applications.

- **AC-01.08**: **Given** the desktop panel, **When** I need Feishu setup, **Then** the footer connection entry (AC-20.02) opens an attached connection card with both a QR code and an official web link; the page and Settings contain no large onboarding block. After authorization the entry identifies Feishu or Lark from the saved enrollment.

Implementation: [registration state machine](../Sources/LunletFeishu/RegistrationFlow.swift), [minimal manifest](../Sources/LunletFeishu/RegistrationManifest.swift), [bounded native HTTP client](../Sources/LunletFeishu/RegistrationClient.swift), [credential file](../Sources/LunletSecureStorage/CredentialFileStore.swift), [file and migrating enrollment stores](../Sources/LunletFeishu/EnrollmentStore.swift), [file store tests](../Tests/LunletSecureStorageTests/CredentialFileStoreTests.swift), [migration tests](../Tests/LunletFeishuTests/FileEnrollmentStoreTests.swift), [Keychain store](../Sources/LunletFeishu/EnrollmentStore.swift), [protocol and HTTP tests](../Tests/LunletFeishuTests/RegistrationClientTests.swift), [attached onboarding card](../Sources/LunletDesktop/FeishuSetupPanel.swift), [setup tests](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [owner-message client](../Sources/LunletFeishu/BotClient.swift), [endpoint discovery](../Sources/LunletFeishu/ConnectionEndpoint.swift), [long-connection runner](../Sources/LunletFeishu/FeishuConnectionRunner.swift), [native loopback transport](../Tests/LunletFeishuTests/FeishuSocketTests.swift), [Synthetic namespace compatibility tests](../Tests/LunletFeishuTests/EnrollmentStoreTests.swift).

### US-20: Choose one mobile communication channel

Status: Confirmed.

Product page: #away.

**As a developer, I want to select one supported communication channel in Settings, so that Lunlet sends notifications and supported replies through my preferred service.**

Acceptance criteria:

- **AC-20.01**: **Given** communication settings, **When** I choose a channel, **Then** only one channel is selected at a time, from Feishu/Lark, Slack, and Telegram, with no WhatsApp entry.
- **AC-20.02**: **Given** a selected channel, **When** I open the desktop panel, **Then** the compact lower-left footer entry identifies that service with a connection-state symbol, the channel name and an expansion indicator, shows its overall state as the worst of its readiness stages (AC-22.03), and only a verified live connection may be labeled connected.
- **AC-20.03**: **Given** an eligible session notification, **When** mobile delivery and replies are enabled for the selected channel, **Then** they use that channel while retaining owner verification and exact session, turn, and request binding; ordinary chat messages do not become ambiguous session input.

- **AC-20.04**: **Given** Slack or Telegram setup, **When** I enter my own bot credentials and prove possession of a private conversation using a fresh, expiring pairing code shown on my Mac, **Then** Lunlet binds notifications to that verified private recipient and keeps the credentials under the AC-01.02 rule; group chats, stale codes and unrelated users do not bind it. No public server, webhook or inbound port is required (transports in [design notes](design.md#messaging-transports)). Each credential field identifies the exact provider menu used to obtain it; setup does not assume that developers already know the token terminology. Credentials I have typed stay in the card until I connect, cancel or switch channel, even when the panel closes while I copy the next one.
- **AC-20.05**: **Given** setup, notification delivery or saved authorization, **When** I change channels, cancel setup, disconnect or quit, **Then** obsolete work cannot activate a different channel or update current delivery state, and pending work is canceled. Saved authorization alone never claims delivery success.
- **AC-20.06**: **Given** supported credentials, **When** authorization is checked or a completion is delivered, **Then** only verified provider identities and matching private-chat receipts establish the respective stage, and an uncertain send is reported as such and not retried (AC-10.03). Reading saved credentials never prompts; only the one-time move of a Keychain-era connection asks, through Authorize access (AC-01.02).

Implementation: [provider adapters](../Sources/LunletMessaging/SlackBotClient.swift), [Telegram client](../Sources/LunletMessaging/TelegramBotClient.swift), [shared bounded network owner](../Sources/LunletMessaging/ChannelHTTPClient.swift), [file, migrating and Keychain credential stores](../Sources/LunletMessaging/ChannelCredentialStore.swift), [file store tests](../Tests/LunletMessagingTests/FileChannelCredentialStoreTests.swift), [native setup](../Sources/LunletDesktop/BotChannelSetupModel.swift), [selected-channel runtime](../Sources/LunletDesktop/CompanionRuntime.swift), [Provider tests](../Tests/LunletMessagingTests/SlackBotClientTests.swift), [Telegram expiry/receipt tests](../Tests/LunletMessagingTests/TelegramBotClientTests.swift), [storage tests](../Tests/LunletMessagingTests/ChannelCredentialStoreTests.swift), [setup lifecycle tests](../Tests/LunletDesktopTests/BotChannelSetupModelTests.swift), [runtime regressions](../Tests/LunletDesktopTests/CompanionRuntimeTests.swift), [Setup instructions](messaging.md), [shared secure storage](../Sources/LunletSecureStorage/SecureItemStore.swift), [application menu](../Sources/LunletDesktop/ApplicationMenu.swift) and its [test](../Tests/LunletDesktopTests/ApplicationMenuTests.swift), which route Cmd-V and the other edit keys into the token fields.

### US-22: Understand readiness and recover from a blocked connection

Status: Confirmed.

**As a developer, I want a compact view of authorization, notification delivery, reply reception, and session-input readiness, so that I can resolve the actual blocker without repeating unrelated setup.**

Acceptance criteria:

- **AC-22.01**: **Given** a partially configured integration, **When** I inspect its connection details, **Then** each supported stage has its own factual state and an actionable recovery step rather than a blanket connected label.
- **AC-22.02**: **Given** a denied credential read or failed delivery, **When** I choose the relevant recovery action, **Then** the result updates that stage without resetting the bot or unrelated local session state.
- **AC-22.03**: **Given** the attached connection card and a saved connection, **When** I open it, **Then** it shows the same factual readiness stages as Settings, listing only stages this build supports, each colored by state (green for verified facts: credentials accepted, private chat paired, a notification delivered; blue while in progress or armed; orange when I must act; red when a step failed; gray when not set up); replies and session input are never implied by these colors. Before a connection is saved the card gives that room to the setup steps instead.

Implementation: [Connection readiness](../Sources/LunletDesktop/FeishuSetupModel.swift), [Messaging settings](../Sources/LunletDesktop/PreferencesPane.swift), [The regression](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [HTTP boundary tests](../Tests/LunletFeishuTests/BotClientTests.swift), [coordinator regressions](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [stage list](../Sources/LunletDesktop/CompanionPanel.swift), [Slack/Telegram](../Sources/LunletDesktop/BotChannelSetupModel.swift), [bot](../Tests/LunletDesktopTests/BotChannelSetupModelTests.swift).

### US-05: Keep mobile continuation available for all active sessions

Status: Confirmed.

Product page: #away.

**As a developer, I want mobile continuation to cover all active sessions and keep the Mac reachable, so that I can step away without configuring individual sessions or power settings.**

Acceptance criteria:

- **AC-05.01**: **Given** a channel is connected, **When** delivery is active (AC-05.06), **Then** notifications cover all observable active sessions automatically, including sessions discovered while it stays active; mobile continuation is available only for independently eligible original CLI sessions.
- **AC-05.02**: **Given** active sessions are already waiting for input or idle after a finished turn, **When** delivery becomes active, **Then** their current state and independently eligible continuation controls become available on the channel without waiting for another session event; these initial-state cards are not replayed completion notifications, and pending execution approvals remain Mac-only.
- **AC-05.03**: **Given** the selected channel's setup is incomplete or its connection is unavailable, **When** I inspect mobile continuation, **Then** Lunlet explains what is unavailable without reporting remote access as ready; local session monitoring remains available.
- **AC-05.04**: **Given** delivery is active, **When** work is running, waiting, or idle after a turn, **Then** Lunlet prevents idle system sleep while allowing screen locking and display sleep.
- **AC-05.05**: **Given** delivery is active, **When** it ends or I quit Lunlet, **Then** Lunlet releases its sleep-prevention request and restores the system's normal power behavior.
- **AC-05.06**: **Given** saved owner authorization, **When** the Mac is confirmed locked, **Then** completion notifications activate automatically; unlocking, disconnecting, or quitting stops delivery. Unknown lock state does not enable delivery. Remote input retains its independent eligibility checks.
- **AC-05.07**: **Given** the main panel, **When** I inspect mobile access, **Then** it has no delivery toggle: delivery follows the lock (AC-05.06) and the only switch is phone replies in Settings (AC-05.08).
- **AC-05.08**: **Given** messaging settings, **When** I inspect phone replies, **Then** a switch allows replies from my phone, enabled by default; turning it off rejects new mobile input and invalidates every issued reply control under AC-12.02, without stopping completion notifications.
- **AC-05.09**: **Given** phone replies are allowed, saved owner authorization and a confirmed locked Mac, **When** an eligible original CLI session finishes a turn or asks an ordinary question, **Then** its notice carries single-use reply controls for a reply window of ten minutes while the Mac stays locked; when the Mac unlocks or the window ends, the controls stop working and later submissions receive an accurate rejection (AC-36.03 rewrites the notice as closed). Execution approvals remain Mac-only and ineligible sessions stay notification-only.

Revisions: the earlier "Away Mode" wording of AC-05.01 through AC-05.05 named the same transitions as a user switch; delivery has followed the lock since AC-05.06 and the only switch is AC-05.08.

Implementation: [owned idle-sleep assertion](../Sources/LunletDesktop/IdleSleepAssertion.swift), [opt-in runtime test](../Tests/LunletDesktopTests/IdleSleepAssertionTests.swift), [mobile coordinator](../Sources/LunletFeishu/MobileCoordinator.swift), [synthetic tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift), [Away model](../Sources/LunletDesktop/AwayModeModel.swift), [tests](../Tests/LunletDesktopTests/AwayModeModelTests.swift), [notification owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [Feishu sender](../Sources/LunletDesktop/FeishuCompletionSender.swift), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [Service tests](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [flow tests](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift), [completion card](../Sources/LunletFeishu/SessionCard.swift), [kept beside the enrollment](../Sources/LunletDesktop/FeishuOwnerMemory.swift), [test](../Tests/LunletDesktopTests/FeishuOwnerMemoryTests.swift).

### US-06: Receive concise, actionable notifications

Status: Confirmed.

Product page: #away.

**As a developer, I want short summaries on my channel when work finishes, fails, or needs me, so that I can decide what to do next without reading the full conversation.**

Acceptance criteria:

- **AC-06.01**: **Given** delivery is active (AC-05.06), **When** a monitored session finishes a turn, fails, asks an ordinary question, or needs execution approval, **Then** its notification identifies the project and session and explains the event with necessary context.
- **AC-06.02**: **Given** a completion notification, **When** I read it, **Then** every channel carries the same facts: the evidenced outcome (succeeded, failed, stopped, finished without an outcome, or needing me on the Mac), the project, the agent and the session title (or a short form of my request when the title is only a placeholder), an excerpt of my latest request of about 140 characters, and the agent's complete final reply with its Markdown kept readable, shortened only to fit that channel's message limit and then ending with "… The rest is on your Mac.", or a line saying that no reply was captured. On Slack and Telegram the notice shows the agent and the event with the project as its heading, the session title when it is not a placeholder, the request as a quote, the reply, any notes and, when the notice can take a reply, one line saying how (US-36); it has no footer, because those channels show the time themselves. The Feishu card follows Feishu's own card conventions instead: a header tinted by the outcome whose title names the agent and the event, such as "Codex finished", with the project, the session title when it is not a placeholder and the local time as the subtitle, and the reply's state as a tag; the request in a tinted block labeled "You asked"; the reply in a bordered block labeled with the agent, with any notes kept inside it; no divider and no footer. A Claude Code card ends with a quiet line that replies from my phone are not available yet; a Codex card says nothing, because its reply box may still be added.
- **AC-06.03**: **Given** the first-release summary path, **When** a notification is prepared, **Then** Lunlet uses the agent's own final reply and confirmed state, without another model account, API key or paid summarization service.
- **AC-06.04**: **Given** a question's context does not fit the channel's message limit, **When** Lunlet notifies me, **Then** it asks me to return to the Mac rather than omitting context needed for a reliable answer.
- **AC-06.05**: **Given** a notification or question card is prepared, **When** Lunlet sends it to the selected channel, **Then** it goes only to my own paired bot and private chat and carries only the request excerpt, the final reply and the question context of AC-06.02 and AC-06.04; values that look like keys or tokens and hidden reasoning are removed and home folders shortened, and Lunlet never adds credentials, authentication files, tool output, files or the rest of the conversation.

Implementation: [Codex reader](../Sources/LunletCodex/CodexSessionReader.swift), [Claude reader](../Sources/LunletClaude/ClaudeTranscriptReader.swift), [observation owner](../Sources/LunletDesktop/SessionObservationModel.swift), [`SessionNotice`](../Sources/LunletCore/SessionSnapshot.swift), [`NoticeText`](../Sources/LunletCore/NoticeText.swift), [Feishu card](../Sources/LunletFeishu/SessionCard.swift), [Slack](../Sources/LunletMessaging/SlackNoticeMessage.swift), [Telegram](../Sources/LunletMessaging/TelegramNoticeMessage.swift), [notice](../Tests/LunletCoreTests/SessionNoticeTests.swift), [text shaping](../Tests/LunletCoreTests/NoticeTextTests.swift), [card](../Tests/LunletFeishuTests/SessionCardTests.swift), [Slack and Telegram](../Tests/LunletMessagingTests/NoticeMessageTests.swift), [Codex](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [Claude](../Tests/LunletClaudeTests/ClaudeTranscriptReaderTests.swift), [preview render](../Tests/LunletDesktopTests/NoticePreviewRenderTests.swift), [locked completion owner](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [Regressions](../Tests/LunletDesktopTests/LockedCompletionNotificationsTests.swift), [owner-only card delivery](../Sources/LunletFeishu/BotClient.swift), [synthetic HTTP tests](../Tests/LunletFeishuTests/BotClientTests.swift).

## EPIC-04: Continue the correct existing CLI conversation safely

Outcome: Move an unfinished task forward from its bound card while retaining its original context and authority.

### US-07: Answer an ordinary question from mobile

Status: Confirmed.

**As a developer, I want to answer the current question from its notice, so that the original session can continue while I am away.**

Acceptance criteria:

- **AC-07.01**: **Given** a verified ordinary question is pending, **When** I open its card, **Then** I see sufficient question context and the applicable options or text input.
- **AC-07.02**: **Given** I submit an answer, **When** Lunlet forwards it, **Then** it targets that exact session, turn, and pending request and retains the original context.
- **AC-07.03**: **Given** the question was already answered, cancelled, expired, or superseded, **When** I submit its old card, **Then** no answer is forwarded and I receive an explanation.
- **AC-07.04**: **Given** the request may authorize execution or its purpose cannot be established, **When** Lunlet evaluates it, **Then** mobile answering is unavailable even if the protocol calls it a user-input request.
- **AC-07.05**: **Given** multiple monitored sessions, **When** I answer from mobile, **Then** the answer reaches only the session, turn and question request bound to that notice (AC-10.04); on Feishu, messages outside the card form are never input, and on Slack and Telegram only the reply forms of AC-36.02 are.

Implementation: [continuation gate](../Sources/LunletCore/ContinuationGate.swift), [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [card renderer and tests](../Tests/LunletFeishuTests/SessionCardTests.swift), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift).

The [callback decoder](../Sources/LunletFeishu/CardCallback.swift), [typed form mapping](../Sources/LunletFeishu/CardForm.swift), and [serialized router](../Sources/LunletFeishu/CardActionRouter.swift) connect synthetic provider callbacks to the gate. [Router tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) verify exact question IDs, permitted options, stale controls, and Mac-only approval handling. Question presentation and provenance remain outstanding; authenticated ingress and Codex dispatch are shared with the US-08 follow-up path.

### US-08: Send a follow-up to the same session

Status: Confirmed.

Product page: #away.

**As a developer, I want to add a follow-up instruction after a turn finishes, so that I can move the unfinished task forward in the same conversation.**

Acceptance criteria:

- **AC-08.01**: **Given** the original CLI session is still open and ready for follow-up, **When** I submit an instruction from its notice on the selected channel, **Then** the next turn uses that session's identity and existing context.
- **AC-08.02**: **Given** the instruction is accepted, **When** Codex processes it, **Then** its existing sandbox and approval policy remain in force.
- **AC-08.03**: **Given** the session has ended, is executing a new turn, or is waiting for execution approval, **When** I submit a stale follow-up card, **Then** Lunlet does not start a new session or take over the running turn (approvals: AC-09.02).
- **AC-08.04**: **Given** the next turn produces a result, **When** it is available, **Then** its notification and receipt remain associated with the original session.
- **AC-08.05**: **Given** a completion card with an eligible follow-up form, **When** I submit an instruction, **Then** the target is the session bound to that notice under AC-10.04, never the latest active session or bot-chat ordering; a notice for one session cannot submit to another.

Implementation: [session monitor](../Sources/LunletCodex/CodexSessionMonitor.swift), [queue adapter](../Sources/LunletCodex/CodexQueueAdapter.swift), [process reader](../Sources/LunletCodex/CodexProcessReader.swift), [rollout watch](../Sources/LunletCodex/CodexDeliveryWatch.swift), [Session-named receipts](../Sources/LunletFeishu/ReplyReceiptCard.swift), [adapter and process runner](../Tests/LunletCodexTests/CodexQueueAdapterTests.swift), [binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift), [reply service](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [end-to-end flow](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift).

The [continuation gate](../Sources/LunletCore/ContinuationGate.swift) and [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) additionally reject stale follow-up controls when the observed context changes. The [card router](../Sources/LunletFeishu/CardActionRouter.swift) binds follow-up forms to authenticated send receipts and the current connection; [integration tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) keep two sessions with identical turn names separate. The [mobile coordinator and tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) additionally verify publication-to-claim handoff for two sessions with the same turn name.

### US-09: Keep execution approvals on the Mac

Status: Confirmed.

Product page: #away.

**As a developer, I want execution approvals to remain on my computer, so that limited mobile continuation does not broaden the agent's authority.**

Acceptance criteria:

- **AC-09.01**: **Given** Codex needs execution approval, **When** the notice reaches me, **Then** it asks me to approve on the Mac and provides no mobile approval control.
- **AC-09.02**: **Given** I send text such as "yes" or "continue", **When** an execution approval is pending, **Then** Lunlet does not translate that text into authorization.
- **AC-09.03**: **Given** a follow-up requires an action outside the session's permissions, **When** Codex requests approval, **Then** it waits for the original desktop approval process; the session's sandbox and approval policy stay as they were (AC-08.02).

Implementation: [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [gate](../Sources/LunletCore/ContinuationGate.swift), [Card-action tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift), [rendered approval cards](../Sources/LunletFeishu/SessionCard.swift), [rendering tests](../Tests/LunletFeishuTests/SessionCardTests.swift), [live binding](../Sources/LunletCodex/CodexSessionMonitor.swift), [Binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift).

### US-10: Receive reliable action receipts

Status: Confirmed.

**As a developer, I want each mobile action to have a clear outcome and execute at most once, so that I can trust the result despite retries or repeated taps.**

Acceptance criteria:

- **AC-10.01**: **Given** an action is received, **When** its status changes, **Then** the receipt distinguishes received, sent to Codex, delivered (confirmed from the session's record), not confirmed, and not sent with the reason; these are the words every channel uses, and transport success alone is never task success.
- **AC-10.02**: **Given** a duplicate callback, repeated tap, or out-of-order operation, **When** it arrives, **Then** it cannot cause duplicate execution or answer a later request accidentally.
- **AC-10.03**: **Given** submission times out and the outcome is unknown, **When** Lunlet reports the result, **Then** it states that uncertainty and does not blindly resubmit.
- **AC-10.04**: **Given** a mobile action arrives, **When** Lunlet validates it, **Then** input is forwarded only if the owner and application, local installation, session, turn or request, and validity period all match the current eligible state, revalidated at that moment; unauthorized, mismatched, stale, or expired actions, including any received during an interruption or before a restart, are rejected with the reason and never guessed onto a foreground destination. This is the binding rule US-07, US-08, US-11 and US-36 refer to.

Implementation: [gate](../Sources/LunletCore/ContinuationGate.swift), [typed models](../Sources/LunletCore/ContinuationModels.swift), [core tests](../Tests/LunletCoreTests/ContinuationGateTests.swift), [Provider decoding tests](../Tests/LunletFeishuTests/CardCallbackTests.swift), [router tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift), [router](../Sources/LunletFeishu/CardActionRouter.swift), [Traceability checks](../scripts/check_traceability.py), [reply service](../Sources/LunletFeishu/FeishuReplyService.swift), [receipt card](../Sources/LunletFeishu/ReplyReceiptCard.swift), [service](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [adapter](../Tests/LunletCodexTests/CodexQueueAdapterTests.swift), [flow](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift).

The [frame assembler](../Sources/LunletFeishu/FrameAssembler.swift) and [wire tests](../Tests/LunletFeishuTests/FrameAssemblerTests.swift) verify bounded fragment assembly and acknowledgments without losing 64-bit identity. The [native socket tests](../Tests/LunletFeishuTests/FeishuSocketTests.swift) verify one authorization for a repeated bound callback and no action from malformed input. A provider acknowledgment remains distinct from Codex submission and processing. The [coordinator](../Sources/LunletFeishu/MobileCoordinator.swift) applies atomic revisioned router state and claims each accepted action once immediately before adapter handoff; [tests](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) reject delayed synchronization and queued actions after access changes or an observation outage, even if the original state returns. Current transport verification is recorded in [feasibility](feasibility.md#messaging-channels).

### US-11: Handle unavailable and ended sessions

Status: Confirmed.

**As a developer, I want unavailable or ended sessions to stop accepting mobile actions, so that delayed messages cannot restart work or reach the wrong request.**

Acceptance criteria:

- **AC-11.01**: **Given** the Mac sleeps, loses network access, or otherwise becomes unreachable, including after lid closure, **When** mobile continuation is unavailable, **Then** the connection card's readiness stages (US-22) show the unavailable stage; Lunlet does not promise execution while offline or assume that closing the lid preserves reachability.
- **AC-11.02**: **Given** mobile instructions were sent during an interruption, **When** the connection recovers, **Then** Lunlet does not execute them; a fresh submission passes AC-10.04 again.
- **AC-11.03**: **Given** a CLI session actually ends, **When** Lunlet detects that exit, **Then** its mobile continuation stops and its old cards become invalid; Lunlet does not restart Codex or restore history automatically.
- **AC-11.04**: **Given** I restore the session on the Mac, **When** it becomes active again, **Then** Lunlet rediscovers it and includes it while delivery is active, without reviving old cards.
- **AC-11.05**: **Given** Lunlet restarts, **When** monitoring recovers, **Then** previously received actions are not replayed, and new input passes AC-10.04 against the recovered state.
- **AC-11.06**: **Given** a terminal window closes or a thread remains loaded, **When** Lunlet determines eligibility, **Then** it uses verified session lifecycle evidence rather than window presence or loaded-thread status alone.

Implementation: [binding](../Tests/LunletCodexTests/CodexContinuationBindingTests.swift), [router](../Tests/LunletFeishuTests/CardActionRouterTests.swift).

The [core gate and tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) now reject unverified lifecycle evidence and permanently retire an ended connection identity. Restoring a session requires a fresh verified connection. The [coordinator](../Sources/LunletFeishu/MobileCoordinator.swift) preserves observed end-of-session tombstones and forwards lifecycle invalidation into the router; [regressions](../Tests/LunletFeishuTests/MobileCoordinatorTests.swift) reject a delayed alive snapshot for an ended binding. Actual lifecycle detection remains an integration responsibility.

The [card router](../Sources/LunletFeishu/CardActionRouter.swift) requires fresh observations and controls after its Feishu connection changes. [Synthetic recovery tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) reject old cards after connection replacement or access changes; the [connection runner tests](../Tests/LunletFeishuTests/FeishuConnectionRunnerTests.swift) verify fresh discovery, retry limits, cancellation, and explicit recovery for authentication/protocol errors. The [native socket](../Sources/LunletFeishu/FeishuSocket.swift) closes on confirmed loss from an owned [network-path observer](../Sources/LunletFeishu/FeishuNetworkPath.swift); injected path-loss tests reject queued callbacks and invalidate old controls. Real network loss/recovery and OS path notifications remain unaccepted.

### US-36: Reply from Slack or Telegram

Status: Confirmed. Depends on US-20 for the paired private chat, US-08 and US-10 for the continuation and receipt rules, and US-05 for the locked-Mac reply window.

**As a developer away from my Mac, I want to continue a finished Codex session from a Slack or Telegram notice, so that the two text channels are as useful as the Feishu card.**

Product page: #away.

Acceptance criteria:

- **AC-36.01**: **Given** Slack or Telegram is the selected channel, the Mac is confirmed locked and an eligible Codex turn finishes, **When** the notice is sent, **Then** it ends with a reply button that opens the reply box (Telegram) or one line inviting a reply in its thread (Slack) for the AC-05.09 reply window; a Claude Code turn not held by the US-38 hook, a child task or an ineligible session carries no such line.
- **AC-36.02**: **Given** such a notice, **When** a message arrives for the bot, **Then** it is forwarded only if it comes from the paired owner in the paired private chat, answers that notice (Telegram's reply to it or to the prompt its button opened, Slack's thread), arrives within the AC-05.09 reply window, is plain text of at most 1,000 characters, and no reply for that turn was accepted before; it then continues that same session through the US-08 path under the AC-10.04 binding rule. Any other message is ignored, and a late or repeated reply to a known notice is answered with the reason, never forwarded.
- **AC-36.03**: **Given** an accepted reply, **When** its state changes, **Then** the notice itself is rewritten in place with the AC-10.01 receipt words, and an open notice is rewritten as closed when its reply window ends or a newer notice replaces it; a plain line is sent only when the provider refuses the rewrite.
- **AC-36.04**: **Given** no notice can take a reply, **When** Lunlet is idle, **Then** nothing polls or listens for replies; a listener runs only while a notice is within its reply window, no webhook is ever set, and tokens stay under the AC-01.02 rule.

Implementation: [reply service](../Sources/LunletMessaging/BotReplyService.swift), [notice states](../Sources/LunletMessaging/NoticeReply.swift), [Telegram client](../Sources/LunletMessaging/TelegramBotClient.swift), [Slack client](../Sources/LunletMessaging/SlackBotClient.swift), [channel sender](../Sources/LunletDesktop/OwnerChannelCompletionSender.swift), [product page stills](../Tests/LunletDesktopTests/ChannelChatScenery.swift); [service tests](../Tests/LunletMessagingTests/BotReplyServiceTests.swift), [sender tests](../Tests/LunletDesktopTests/OwnerChannelCompletionSenderTests.swift), [Telegram tests](../Tests/LunletMessagingTests/TelegramBotClientTests.swift), [Slack tests](../Tests/LunletMessagingTests/SlackBotClientTests.swift), [notice tests](../Tests/LunletMessagingTests/NoticeMessageTests.swift).

### US-38: Continue a Claude Code session from the phone

Status: Confirmed. The mechanism is Claude Code's Stop hook, which needs no interaction; a channel plugin was ruled out because it needs a launch flag and a confirmation. Depends on US-33 for session observation, US-08, US-10 and US-11 for the continuation, receipt and ended-session rules, US-05 for the reply window and US-36 for Slack and Telegram replies.

**As a developer who uses Claude Code, I want to send a follow-up to the Claude Code session named in a completion notice, so that the same conversation continues while I am away, as it does for Codex.**

Acceptance criteria:

- **AC-38.01**: **Given** Claude Code is a selected agent, **When** Lunlet starts or Claude Code becomes selected, **Then** Lunlet adds its Stop hook to Claude Code's user settings, changing only its own entry under `hooks.Stop` and nothing else in the file; turning Claude Code off removes exactly that entry, there is no separate switch, and the hook's command is a launcher in Lunlet's own user-only folder that runs the helper this build bundles and exits silently when Lunlet is gone. Claude Code applies the entry to sessions already running (observed 2026-11-06).
- **AC-38.02**: **Given** a session started after the hook was connected, **When** a turn ends, **Then** the helper Claude Code ran inside that session announces the finished turn with the final reply text and holds it open only while Lunlet's reply window is open (the Mac locked, AC-05.09) and only when the helper's parent is the session's own process; a notice carries a reply control only for a turn held that way, every other Claude notice stays notification-only, and the hold ends at once when I unlock, when the window's ten minutes pass, or when Lunlet quits.
- **AC-38.03**: **Given** an accepted follow-up for a held turn, under the same gates as AC-08.01 through AC-08.05 and AC-10.04, **When** Lunlet forwards it, **Then** the helper hands it to Claude Code as the documented non-error hook feedback that continues the same turn with it as my next message, under the session's existing permission mode, with no hook error shown; Lunlet never answers a permission prompt (AC-09.01).
- **AC-38.04**: **Given** a forwarded follow-up, **When** Lunlet confirms delivery, **Then** it confirms from the session's own transcript, where the first hook record appended after the hand-over must carry the reply; the receipt uses the AC-10.01 words, reports "not confirmed" when the record does not show it within the window, and nothing is handed over twice.
- **AC-38.05**: **Given** the continued turn ends, **When** the helper announces it again, **Then** the completion notice and the receipt stay associated with the original session under a new turn id (AC-08.04), the first completion is never replayed (AC-13.04), and the hook record is read only for that confirmation, within the AC-33.07 limits.
- **AC-38.06**: **Given** Settings › Agents, **When** I view it, **Then** the Claude Code switch's help says that Lunlet adds its Stop hook for phone replies while Claude Code is selected and removes it when it is turned off, and a note with Try again appears only when Claude Code's settings could not be changed; there is no switch, status or per-session list for the hook, as there is none for Codex replies.
- **AC-38.07**: **Given** the hook is connected, **When** a turn ends while Lunlet is not running, or while the Mac is unlocked, **Then** the helper exits at once or within the moment Lunlet answers, the turn ends as usual, nothing is logged, and the helper reads and writes nothing outside Lunlet's own stop folder; a stop folder left by an ended helper is swept by Lunlet.
- **AC-38.08**: **Given** a held turn, **When** Claude Code shows the session, **Then** its spinner reads "Lunlet: waiting for your phone reply" while the hook holds, the hook's timeout in the settings exceeds the reply window so Claude Code never ends a hold first, and Claude Code's own cap of eight consecutive hook continuations is documented as the limit of replies without a typed prompt.

Implementation choices (rules in [design notes](design.md#claude-code-stop-hook)): the helper is a small Swift program that reads the Stop event on its standard input and answers with Claude Code's documented `additionalContext` form; the app and the helper meet through per-stop files in Lunlet's user-only hook folder, each answered by a verdict and, for a follow-up, a receipt; a completion the helper announces is keyed by the prompt id and the number of hook continuations, which the transcript reader counts too, so both sources name the same turn.

Implementation: [hook folder](../Sources/LunletHook/HookSpool.swift), [hook input and output](../Sources/LunletHook/HookExchange.swift), [helper runtime](../Sources/LunletHook/HookRuntime.swift), [helper program](../Sources/LunletHookHelper/main.swift), [settings connection and installation](../Sources/LunletClaude/ClaudeHookConnection.swift), [delivery watch](../Sources/LunletClaude/ClaudeDeliveryWatch.swift), [adapter and binding](../Sources/LunletClaude/ClaudeContinuation.swift), [monitor](../Sources/LunletClaude/ClaudeSessionMonitor.swift), [transcript reader](../Sources/LunletClaude/ClaudeTranscriptReader.swift), [input path](../Sources/LunletCore/SessionSnapshot.swift), [dispatch](../Sources/LunletDesktop/ReplyDispatch.swift), [reply window](../Sources/LunletDesktop/SessionObservationModel.swift), [lock observer](../Sources/LunletDesktop/LockedCompletionNotifications.swift), [hook owner](../Sources/LunletDesktop/ClaudeHookModel.swift), [settings note](../Sources/LunletDesktop/ClaudeHookSettings.swift), [agents help](../Sources/LunletDesktop/PreferencesPane.swift), [bundle assembly](../scripts/build-app.sh), [signing](../scripts/sign-app.sh); [helper tests](../Tests/LunletHookTests/HookRuntimeTests.swift), [hook tests](../Tests/LunletClaudeTests/ClaudeHookTests.swift), [reply gates](../Tests/LunletFeishuTests/FeishuReplyServiceTests.swift), [card form](../Tests/LunletFeishuTests/SessionCardTests.swift), [bot replies](../Tests/LunletMessagingTests/BotReplyServiceTests.swift), [end-to-end Codex flow](../Tests/LunletDesktopTests/PhoneReplyFlowTests.swift), [settings editor](../Sources/LunletClaude/ClaudeSettingsEditor.swift), [hook model recovery](../Tests/LunletDesktopTests/ClaudeHookModelTests.swift).

## EPIC-05: Personalize a focused and durable macOS interface

Outcome: Choose supported presentation and settings without adding clutter, losing preferences or mistaking planned providers for working integrations.

### US-31: Find focused controls in a categorized Settings interface

Status: Confirmed.

**As a developer, I want Lunlet settings grouped by purpose in a native macOS interface, so that I can find and understand its configuration without cluttering the main panel.**

Acceptance criteria:

- **AC-31.01**: **Given** an expanded set of preferences, **When** I open Settings, **Then** related options are grouped into focused categories rather than one long undifferentiated list.
- **AC-31.02**: **Given** a settings category, **When** I inspect its controls, **Then** each control states what it changes and names what it depends on, and no planned or unavailable integration is presented as a working feature.
- **AC-31.03**: **Given** the categorized settings, **When** I return to the main panel, **Then** sessions and usage remain the primary content while application configuration stays in Settings.
- **AC-31.04**: **Given** the first-release settings, **When** I open them, **Then** Appearance is the initial category; no empty General category or whole-settings import/export/reset controls are exposed. Skin import/export remains in Appearance and property-level reset remains contextual to its control.

Implementation: [Native categorized preferences](../Sources/LunletDesktop/PreferencesPane.swift), [panel navigation](../Sources/LunletDesktop/PanelNavigation.swift), [settings model](../Sources/LunletDesktop/SettingsModel.swift), [rows and tabs](../Sources/LunletDesktop/SettingsRows.swift), [settings tests](../Tests/LunletDesktopTests/SettingsPaneTests.swift).

### US-16: Customize official skin colors

Status: Confirmed.

Product page: #yours.

**As a developer, I want to adjust official notch skin colors in Settings using a macOS-style color control, so that its appearance suits my preferences.**

Acceptance criteria:

- **AC-16.01**: **Given** appearance settings for any official skin, **When** I choose a color, **Then** a continuous color spectrum supports arbitrary hues and a native macOS color picker offers the full RGB range; editing is not limited to presets. The selected color is shown; a compact native Restore button resets the selected official skin directly, without an extra menu or icon, and the continuous control can be adjusted from the keyboard with visible focus.
- **AC-16.02**: **Given** a chosen appearance, **When** I view the notch entry, **Then** its lettering and allowance decoration take their colors from that skin and the chosen color, for every official skin.
- **AC-16.03**: **Given** both agents selected, **When** either agent's allowance or usage appears in the notch strand, a meter, an Overview limit row or a chart segment, **Then** Codex uses the selected palette and Claude Code a clearly distinct sibling of it, differing in hue and lightness and away from the warning hues (the derivation is in [design notes](design.md#agent-colors)), so each agent keeps one color everywhere and both change with the skin color; the yellow and red low-allowance colors of AC-04.10 apply unchanged to both.

Implementation: [Native RGB and continuous color controls](../Sources/LunletDesktop/SkinColorControls.swift), [Appearance](../Sources/LunletDesktop/PreferencesPane.swift), [validated settings](../Sources/LunletDesktop/PreferencesStore.swift), [The shared allowance palette](../Sources/LunletDesktop/AllowancePalette.swift), [Palette regressions](../Tests/LunletDesktopTests/VineEntryTests.swift), [official/imported ownership and lantern rendering](../Tests/LunletDesktopTests/SkinCatalogTests.swift), [continuous hue editing regressions](../Tests/LunletDesktopTests/SkinColorControlsTests.swift).

### US-17: Choose and supply a custom notch skin

Status: Confirmed.

Product page: #yours.

**As a developer, I want to select a built-in notch skin or import my own through configuration, so that I can personalize Lunlet without editing or rebuilding its source code.**

Acceptance criteria:

- **AC-17.01**: **Given** available notch skins, **When** I open appearance settings, **Then** I can choose the skin used by the notch entry.
- **AC-17.02**: **Given** a compatible user-defined style, **When** I add it through the supported configuration or import mechanism, **Then** it becomes selectable without changing Lunlet source code or recompiling the application.
- **AC-17.03**: **Given** an alternative style, **When** it is selected, **Then** device-adaptive notch placement, allowance representation, and entry interaction remain available.
- **AC-17.04**: **Given** the built-in skin selector, **When** I open it, **Then** it offers the vine skin and the red-lantern skin.
- **AC-17.05**: **Given** the red-lantern skin and known weekly remaining allowance, **When** the compact entry is shown, **Then** five red lanterns replace the outer progress vine between lun and let. Each lantern represents 20 percentage points; as its represented allowance is depleted, its brightness gradually decreases until it is extinguished. All five are lit at 100% and all five are extinguished at 0%.
- **AC-17.06**: **Given** the red-lantern skin, **When** the entry is displayed, **Then** the lun and let lettering uses the lantern skin's colors and alignment rather than the vine skin's.
- **AC-17.07**: **Given** unavailable allowance data, **When** either skin is displayed, **Then** its unknown state remains distinguishable from a confirmed zero balance.
- **AC-17.08**: **Given** Appearance settings, **When** I select a skin, **Then** all official skins expose the same color controls immediately beside the skin selector, before custom-skin management. Imported skins own their package colors and do not expose the official palette. Each official skin keeps its own saved color: switching skins shows the selected skin's saved color, or its default when it was never customized (Restore: AC-16.01).
- **AC-17.09**: **Given** the red-lantern skin with both agents selected, **When** the compact entry is shown, **Then** two cords hang from the same wing attachments and cross once under the notch, each carrying five smaller lanterns for one agent (Codex's in the skin's glass, Claude Code's in its AC-16.03 color), interleaved along the width and lit by that agent's own remaining as in AC-17.05; one agent keeps the single cord, and the two are never combined (AC-04.13 is the vine's two-strand form).

The skin package format and its validation are in the [skin guide](skins.md). A plugin-style import experience does not authorize an arbitrary executable-code plugin system.

Implementation: [Skin catalog](../Sources/LunletDesktop/SkinCatalog.swift), [native renderer](../Sources/LunletDesktop/LettermarkView.swift), [lantern scene](../Sources/LunletDesktop/LanternScene.swift), [format guide](skins.md), [catalog tests](../Tests/LunletDesktopTests/SkinCatalogTests.swift), [shared panel tokens](../Sources/LunletDesktop/PanelStyle.swift), [Session rows](../Sources/LunletDesktop/SessionPanel.swift), [Restore](../Sources/LunletDesktop/SessionListHeader.swift), [account card](../Sources/LunletDesktop/AccountUsageSummary.swift), [strand marks](../Sources/LunletDesktop/WeeklyAllowanceMarkers.swift), [usage](../Sources/LunletDesktop/UsageHistoryPanel.swift), [trend](../Sources/LunletDesktop/WeeklyQuotaTrendPanel.swift), [panel](../Sources/LunletDesktop/CompanionPanel.swift), [Panel material](../Sources/LunletDesktop/PanelMaterial.swift), [Settings](../Sources/LunletDesktop/PreferencesPane.swift), [status and age](../Tests/LunletDesktopTests/PanelStyleTests.swift), [entry](../Tests/LunletDesktopTests/VineEntryTests.swift), [trend geometry](../Tests/LunletDesktopTests/WeeklyQuotaTrendTests.swift), [three-row fit](../Tests/LunletDesktopTests/AccountUsagePresentationTests.swift), [keyboard](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [surface](../Sources/LunletDesktop/NotchSurfaceView.swift), [window](../Sources/LunletDesktop/PanelPlacement.swift), [segmented control](../Sources/LunletDesktop/PanelSegmentedControl.swift), [surface](../Tests/LunletDesktopTests/NotchSurfaceTests.swift), [placement and page budget](../Tests/LunletDesktopTests/PanelPlacementTests.swift), [segmented control](../Tests/LunletDesktopTests/PanelSegmentedControlTests.swift), [Claude](../Sources/LunletDesktop/ProviderSummaries.swift), [Claude](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [render of every page](../Tests/LunletDesktopTests/PanelPageRenderTests.swift).

Panel-wide presentation rules (type, grid, materials, meters, page budget) are in [design notes](design.md#panel-presentation).

### US-21: Choose a menu-bar entry instead of the notch widget

Status: Confirmed.

Product page: #yours.

**As a developer, I want to choose a standard right-side macOS menu-bar entry instead of the notch widget, so that I can use Lunlet in the presentation mode I prefer.**

Acceptance criteria:

- **AC-21.01**: **Given** appearance settings, **When** I choose menu-bar mode, **Then** the notch widget is hidden and a standard macOS menu-bar entry opens the Lunlet details panel.
- **AC-21.02**: **Given** menu-bar mode, **When** its entry is visible, **Then** it uses a monochrome template version of the lun·let lettering shown beside the notch, tinted by the system like other menu-bar items on light, dark and tinted menu bars, with any waiting count as plain text beside it, not the application icon or a system symbol.
- **AC-21.03**: **Given** either presentation mode, **When** Lunlet is running, **Then** only one application entry is shown; switching back to notch mode retains the existing no-notch fallback behavior.
- **AC-21.04**: **Given** menu-bar mode and Settings › Appearance, **When** I choose what the entry shows, **Then** a Show allowance picker offers Off (the entry of AC-21.02, the default), Percent, and Percent and reset; with it on, plain text after the lettering and the waiting count shows the window closest to running out among those Lunlet shows (Codex's limit window under AC-04.19, AC-04.15, AC-33.09), as "25%" or "25% · 1d 9h" in the AC-04.01 countdown wording, prefixed by the agent's name when more than one agent is selected and by "5h" for a five-hour window; the text is tinted by the system like the lettering, and a window that is unknown or past its reset shows no text rather than a placeholder.
- **AC-21.05**: **Given** the allowance text, **When** I choose Only below 50%, 30% or 20% left, **Then** the text appears only while the chosen window is below that level and the entry otherwise looks as in AC-21.02; the choices survive upgrades (US-26).

Implementation: [Entry controller](../Sources/LunletDesktop/NotchEntryController.swift), [menu artwork and title](../Sources/LunletDesktop/MenuBarController.swift), [allowance text](../Sources/LunletDesktop/MenuBarAllowanceText.swift), [Appearance settings](../Sources/LunletDesktop/PreferencesPane.swift), [Native regressions](../Tests/LunletDesktopTests/NotchEntryControllerTests.swift), [text tests](../Tests/LunletDesktopTests/MenuBarAllowanceTextTests.swift), [a regression](../Tests/LunletDesktopTests/LunletWordmarkTests.swift).

Revisions: 2026-11-12, AC-21.04 and AC-21.05 (allowance text in the entry) confirmed. 2026-11-13, with AC-04.19, AC-21.04 counts Codex's limit window, weekly or longer, where it named the weekly one; only the five-hour window is marked.

### US-19: Select supported coding agents and see a combined overview

Status: Confirmed.

Product page: #glance.

**As a developer, I want to choose which supported coding agents appear in Settings, so that I can monitor my selected tools together without unrelated providers cluttering the interface.**

Acceptance criteria:

- **AC-19.01**: **Given** provider settings, **When** I choose which supported agents to display, **Then** I can select implemented providers individually. Codex and Claude Code are first-release providers; Settings lists only implemented providers, and a later agent such as Cursor appears only once its interfaces and acceptance gates are satisfied.
- **AC-19.02**: **Given** exactly one selected provider, **When** I open Lunlet, **Then** its provider page is shown without requiring an Overview navigation step.
- **AC-19.03**: **Given** more than one selected provider, **When** I open Lunlet, **Then** an Overview summarizes the selected providers and separate provider pages retain their detailed information.
- **AC-19.04**: **Given** different provider interfaces, **When** information is displayed, **Then** unavailable fields remain unknown and provider-specific limits are not combined into an invented common allowance.
- **AC-19.05**: Replaced by AC-19.09 on 2026-11-13. It described a horizontal tab bar listing Overview and each selected provider.
- **AC-19.06**: Replaced by AC-19.10 on 2026-11-13. It described an Overview Limits card with one block and one meter per selected agent.
- **AC-19.07**: **Given** the Overview, **When** I read the totals row where provider pages switch Active and History, **Then** a Tokens/Cost switch shows today's and the selected range's combined recorded totals in that metric, labeled as lower-bound estimates (switch order: AC-33.10).
- **AC-19.08**: **Given** the Overview, **When** I read the daily chart in the session list's place, **Then** it shows one bar per day of the selected range stacked by agent in each agent's AC-16.03 color, each day's total and the daily average, per-day detail on hover and a legend naming each agent's total for the shown days; the Overview shows no session list, and each provider tab shows that provider's full detail.
- **AC-19.09**: **Given** more than one selected agent, **When** I open the panel, **Then** its header shows one body for each selected agent, in a fixed order with the agent's name always visible, around a central body that stands for all agents; the all-agents view, the Overview, is shown first; choosing an agent's body opens that agent's page, and choosing the central body or the open agent's body again returns to the Overview; the header and the page below it keep one frame, so no choice resizes the panel. With one selected agent there is no central body and the panel shows that agent's page (AC-19.02).
- **AC-19.10**: **Given** the Overview, **When** I read the header, **Then** each agent shows percent left of its weekly window, its name and plan, the window with its reset countdown and today's recorded tokens, and the lit share of its body equals the percent left; the central body shows today's recorded tokens across the selected agents and their estimated cost, a lower bound as the Overview's totals are (AC-19.07). Allowances are never combined (AC-19.04). An agent whose limit is unknown shows a dash, a dimmed outlined body and its state in a word or two (Reading…, Couldn't read, Not connected), never zero and never an earlier value (AC-04.03).
- **AC-19.11**: **Given** the Overview, **When** a session is waiting for me (AC-13.10), **Then** its agent's body carries an attention badge, and one line above the totals names the agent and the count and opens that agent's page; with nothing waiting the line says so. The Overview still lists no sessions (AC-19.08).

Provider compatibility, discovery, usage sources, continuation capabilities, and overview aggregation require separate feasibility validation. Display selection alone does not prove integration readiness. The first release covers Codex and Claude Code phase A (US-33); Claude phone replies and Cursor remain later work.

Implementation: [Settings](../Sources/LunletDesktop/PreferencesPane.swift), [provider preference](../Sources/LunletDesktop/PreferencesStore.swift), [panel](../Sources/LunletDesktop/CompanionPanel.swift), [Overview](../Sources/LunletDesktop/ProviderSummaries.swift), [observation owner](../Sources/LunletDesktop/SessionObservationModel.swift), [provider pages](../Tests/LunletDesktopTests/ProviderOverviewTests.swift), [multi-source owner](../Tests/LunletDesktopTests/SessionObservationModelTests.swift), [header layout](../Sources/LunletDesktop/HeaderLayout.swift), [header labels](../Sources/LunletDesktop/HeaderPresentation.swift), [header](../Sources/LunletDesktop/PanelHeader.swift), [layout tests](../Tests/LunletDesktopTests/HeaderLayoutTests.swift), [header stillness and edge checks](../Tests/LunletDesktopTests/PanelHeaderTests.swift), [label tests](../Tests/LunletDesktopTests/HeaderPresentationTests.swift), [drawn bodies](../Sources/LunletDesktop/HeaderBodyArt.swift), [lit share](../Sources/LunletDesktop/LitShare.swift), [sky](../Sources/LunletDesktop/SkyField.swift), [lit-share tests](../Tests/LunletDesktopTests/LitShareTests.swift), [body tests](../Tests/LunletDesktopTests/HeaderBodyArtTests.swift), [sky tests](../Tests/LunletDesktopTests/SkyFieldTests.swift).

Revisions: 2026-11-13, the panel redesign confirmed: AC-19.09 through AC-19.11 replace the tab bar and the Overview Limits card (AC-19.05, AC-19.06). Presentation rules are in [design notes](design.md#panel-header-and-pages).

### US-39: Keep a desktop pet as the companion entry

Status: Confirmed. Depends on US-02 and US-33 for session state, US-13 for cue rules, US-21 for the entry choice, US-24 for keyboard and assistive access and US-25 for the resource budget. On macOS the notch entry stays; the pet is also the first entry planned for Linux and Windows, so its pose model and drawing description stay free of AppKit.

**As a developer, I want Lunlet to live on my desktop as a small dog that shows what my agents are doing, so that I can keep an eye on them without the notch, and later on a machine that has none.**

Acceptance criteria:

- **AC-39.01**: **Given** Settings › Appearance, **When** I choose the entry, **Then** Notch, Menu bar and Desktop pet are the three choices with exactly one active; choosing the pet hides the notch and menu-bar entries, the choice applies at once and survives upgrades (US-26), and the escape hatches of US-12 stay reachable from the pet's context menu.
- **AC-39.02**: **Given** the pet entry, **When** Lunlet runs, **Then** a dog about 110 points tall sits in a transparent, non-activating window above other windows on every Space, on the display where I last left it while that display is connected and where I last dragged it on that display, never takes keyboard focus, and passes clicks on its transparent area to the window beneath; it hides while the screen is locked or a full-screen app is in front, and returns with the desktop.
- **AC-39.03**: **Given** verified sessions, **When** their state changes, **Then** the dog shows one of six poses chosen by precedence: Waiting for you (a session awaits my answer or approval) over Failed (a turn failed, the AC-13.08 Failed outcome, for the AC-13.02 cue duration) over Done (a turn finished, for the AC-13.02 cue duration) over Working (a turn is running) over Idle (sessions exist, none running) over Asleep (no verified session, or observation unavailable); an unknown state never invents a pose, and a duplicate or replayed event never retriggers Done (AC-13.04).
- **AC-39.04**: **Given** a Waiting or Done pose, **When** it appears, **Then** a bubble above the dog shows "?", "!" for Failed or "✓" and nothing else, and hovering the dog shows the compact status line of the session behind the pose: project or directory, agent and state, as the panel's row does.
- **AC-39.05**: **Given** the pet, **When** I click it, **Then** the session panel opens beside the dog, above it when there is room and below it otherwise, without notch shoulders, with the conversation of the pose's session selected, and closes under the AC-03.06 rules; a right-click offers Open Lunlet, Refresh, Settings and Quit.
- **AC-39.06**: **Given** the drawing, **When** it is rendered, **Then** it is vector shapes drawn in code at any size, with the golden coat by default and Cream and Slate as the other built-in coats, a lantern-red collar with a lantern tag that is lit while Working, pulsing while Waiting, dim while Idle and Failed and off while Asleep, a Failed pose sitting with the ears flat, the head lowered and the tail still, and gentle loops (breathing, tail wag, head bob) that stop under Reduce Motion, while the screen is locked and while the window is hidden.
- **AC-39.07**: **Given** assistive tools, **When** they inspect the pet, **Then** its accessibility label states the pose and the session count, such as "Lunlet: two sessions, one waiting for you" or "Lunlet: two sessions, one turn failed", and the panel and Settings stay reachable from the keyboard through the application menu while the pet is the entry (US-24).
- **AC-39.08**: **Given** the pet runs all day, **When** its cost is measured, **Then** it redraws only on a state change and, for its loops, at no more than 12 frames per second, rising to at most 30 only while something quick happens (a blink, an ear flick, a pose transition, a click bounce, the Done hop, or the pointer or the open panel holding its attention), within the budgets recorded in [feasibility](feasibility.md#performance-and-resources) (US-25).

AC-39.02 revision history: since 2026-11-10 the dog returns to the display where it was last left; before, it followed the display with the focused window after a relaunch.

AC-39.08 revision history: the quick moments at 30 frames per second were added on 2026-11-06, because a blink lasts about a seventh of a second and does not read at 12; the loops keep 12.

AC-39.03, AC-39.04, AC-39.06 and AC-39.07 revision history: on 2026-11-12 the Failed pose was confirmed, in the order Codex Pets uses (needs input, blocked, ready, running).

Implementation choices (rules in [design notes](design.md#desktop-pet)): the pose rule and the state assistive tools read live in the core module, free of AppKit, so a later Linux or Windows entry reuses them; the drawing is a SwiftUI canvas over a 220 × 190 design space, scaled to the window, and every blink, glance, ear flick and bounce is a function of the time so that the frame needs no stored animation state; frames are driven by a timer armed for the next frame rather than a SwiftUI timeline, whose display link keeps waking at the screen's rate however few frames it draws, and the glow, the glyphs and the sleep marks are shapes rather than a blur pass and text (measured on 2026-11-10 in [feasibility](feasibility.md#performance-and-resources)); the macOS window is a floating, non-activating panel on every Space that ignores the pointer except over the dog's own silhouette; the panel opens as the dog's speech bubble, with a tail toward its head, grown from the dog and shrunk back into it; task cues reach the island or the pet, never both.

Implementation: [pose rule and state](../Sources/LunletCore/PetPose.swift), [drawing, canvas and host view](../Sources/LunletDesktop/PetView.swift), [motion between states](../Sources/LunletDesktop/PetMotion.swift), [entry controller and cue router](../Sources/LunletDesktop/PetEntryController.swift), [bubble placement and tail](../Sources/LunletDesktop/PanelPlacement.swift), [bubble silhouette](../Sources/LunletDesktop/NotchSurfaceView.swift), [anchored companion panel](../Sources/LunletDesktop/CompanionPanelController.swift), [one entry at a time](../Sources/LunletDesktop/MenuBarController.swift), [runtime](../Sources/LunletDesktop/CompanionRuntime.swift), [preferences](../Sources/LunletDesktop/PreferencesStore.swift), [appearance settings](../Sources/LunletDesktop/PreferencesPane.swift); [pose tests](../Tests/LunletCoreTests/PetPoseRuleTests.swift), [entry, placement, preferences and silhouette tests](../Tests/LunletDesktopTests/PetEntryControllerTests.swift), [motion and frame clock tests](../Tests/LunletDesktopTests/PetMotionTests.swift), [drawing checks](../Tests/LunletDesktopTests/PetDrawingTests.swift), [pet cost probe](../Tests/LunletDesktopTests/PerformanceBudgetTests.swift), [panel navigation](../Sources/LunletDesktop/PanelNavigation.swift), [application menu](../Sources/LunletDesktop/ApplicationMenu.swift).

### US-40: Bring your own pet

Status: Confirmed. Background is in [pet animation research](research.md). Depends on US-39 for the pet entry, its pose rule and its window, US-26 for preference validation and US-25 for the resource budget. The built-in dog stays as it is; this story adds pets the user brings.

**As a developer, I want to use a pet of my own in Lunlet, including a pet I already made for Codex, so that the companion looks the way I like without my learning a new format.**

Acceptance criteria:

- **AC-40.01**: **Given** Settings › Appearance with the pet entry, **When** I look at the pet choice, **Then** the built-in dog with its coats and every valid pet pack in Lunlet's pets folder (`~/Library/Application Support/com.lunlet/pets/<id>/`) and in Codex's (`~/.codex/pets/<id>/`) are listed by display name, the dog is chosen by default, choosing one applies at once and survives upgrades (US-26), and Refresh, Open pets folder and Find pets on Petdex (the gallery at petdex.dev, opened in the browser) are beside the list; the picker's help says that pets installed with `petdex install` appear through Codex's folder, because Petdex writes every installed pet there too, so no third folder is read.
- **AC-40.02**: **Given** a pet pack in the Codex format (`pet.json` naming a WebP or PNG sheet through `spritesheetPath`; 8 columns of 192 × 208 cells; 9 rows, or 11 rows with `spriteVersionNumber: 2`), **When** Lunlet reads it, **Then** it is used in place, unchanged and uncopied, and Lunlet never writes into `~/.codex`; a pack whose manifest or sheet does not match the format is listed as invalid with the reason, and never crashes, blanks or replaces the current pet (AC-26.02).
- **AC-40.03**: **Given** a chosen pack, **When** the pose of AC-39.03 changes, **Then** Asleep shows the first idle frame still, Idle loops idle, Working loops running, Waiting loops waiting, Done loops review and Failed loops failed for the cue duration; a click plays jumping once, dragging the pet plays running-left or running-right in the direction it moves, and a pack with look directions turns the pet toward the pointer within the dog's gaze range and toward the open panel, with neutral falling back to idle; rows a pack lacks fall back to idle.
- **AC-40.04**: **Given** a looping row, **When** it plays, **Then** each frame holds for the duration the format assigns it, Reduce Motion shows the row's first frame still, and a hidden window or an unavailable display stops the loop within the AC-39.08 budget.
- **AC-40.05**: **Given** a pack is the pet, **When** AC-39.04 and AC-39.05 apply, **Then** the "?" / "✓" bubble, the hover status line, the accessibility label and the panel opening as the pet's bubble work as for the dog, the panel's tail pointing at the top center of the pet's cell; the dog's collar and lantern are not drawn over a pack.
- **AC-40.06**: **Given** a pack is the pet, **When** I click or drag, **Then** only the opaque pixels of the current frame count as the pet and clicks on its transparent space reach the window beneath (AC-39.02); the pet is drawn at about the dog's height, crisp on Retina displays.
- **AC-40.07**: **Given** no pack is valid or the chosen pack disappears, **When** Lunlet starts or refreshes, **Then** the dog returns and Settings says which pack was missing or invalid.

Revisions: 2026-11-12, the failed row (AC-40.03) and the Petdex link and note (AC-40.01) confirmed; Petdex installs every pet into Codex's folder as well, so no folder was added.

Out of scope: generating pets (Codex's `/pet` and its hatch-pet skill do that), bundling third-party pets, skeletal or vector runtimes (Rive, Spine, Live2D, Lottie), Codex's waving and look rows beyond the uses above, and any change to the dog.

Implementation choices (rules in [design notes](design.md#imported-pets)): the pack reader, its validation and the pose-to-row mapping live in the core module on Foundation alone so a later Linux or Windows entry reuses them; decoding and drawing are in the desktop module; frames are drawn from the sheet by cell rectangle, never split into files; the hit test samples the current frame's alpha; preferences store the chosen pack's source and folder, never its pixels.

Implementation: [pack format, reader and frame rule](../Sources/LunletCore/PetPack.swift), [pack library and image reading](../Sources/LunletDesktop/PetPackLibrary.swift), [sheet cells, masks and drawing](../Sources/LunletDesktop/PetSpriteSheet.swift), [pet canvas and hit test](../Sources/LunletDesktop/PetView.swift), [frame clock on the pack's frame boundaries](../Sources/LunletDesktop/PetMotion.swift), [entry controller: choice, fallback and drag](../Sources/LunletDesktop/PetEntryController.swift), [preference](../Sources/LunletDesktop/PreferencesStore.swift), [Settings pet choice](../Sources/LunletDesktop/PreferencesPane.swift); [format, reader and rule tests](../Tests/LunletCoreTests/PetPackTests.swift), [library, pixel, hit-test, fallback and preference tests](../Tests/LunletDesktopTests/PetPackLibraryTests.swift), [opt-in pack render](../Tests/LunletDesktopTests/PetRenderTests.swift).

### US-42: Keep the entry out of full-screen video

Status: Confirmed.

**As a developer, I want the notch entry to step aside while another application fills the display with video, so that nothing sits on top of what I am watching or presenting.**

Acceptance criteria:

- **AC-42.01**: **Given** the notch entry and another application whose full-screen window is in front on that display, **When** that application keeps the display awake, as video, a presentation or a call does, **Then** the entry fades from the display within about a second together with an open panel, and no cue appears there. It stays away while that window remains in front, so a pause or a moment of buffering does not bring it back over the picture, and it fades in again when the application leaves full screen or another application comes in front. With Reduce Motion it leaves and returns at once.
- **AC-42.02**: **Given** a full-screen application that does not keep the display awake, such as a terminal or an editor, **When** it is in front, **Then** the entry and its cues stay as they are outside full screen.
- **AC-42.03**: **Given** Settings › Appearance with the notch entry selected, **When** I choose Hide in full screen, **Then** During video (the default) behaves as AC-42.01 and AC-42.02, Always hides the entry and its cues under every full-screen application, and Never keeps them; the choice survives upgrades (US-26). The menu-bar entry leaves with the menu bar and the pet stays out of full-screen Spaces (AC-39.02), so neither offers the choice.
- **AC-42.04**: **Given** the detection, **When** it runs, **Then** it uses only the frames and owners of on-screen windows and which processes hold a display-sleep assertion, never a window's title or contents and no recording permission; it reads on a change of Space, application or displays and a few more times as that change settles, and once a second only while a display is in full screen.

Implementation: [full-screen scene and watcher](../Sources/LunletDesktop/FullScreenQuiet.swift), [display state](../Sources/LunletDesktop/DisplayState.swift), [saved choice](../Sources/LunletDesktop/PreferencesStore.swift), [Appearance settings](../Sources/LunletDesktop/PreferencesPane.swift), [tests](../Tests/LunletDesktopTests/FullScreenQuietTests.swift).

### US-26: Keep customization stable across upgrades

Status: Confirmed.

**As a developer, I want validated preferences to survive updates, so that changing styles, providers, or channels does not force me to rebuild my setup.**

Acceptance criteria:

- **AC-26.01**: **Given** preferences from a supported prior version, **When** Lunlet updates, **Then** valid selections are retained or explicitly migrated, an unsupported style does not prevent opening Settings, and an in-app update keeps them (AC-35.02).
- **AC-26.02**: **Given** invalid saved preferences or an invalid imported skin, **When** validation fails, **Then** Lunlet explains the invalid setting and retains a usable last-known configuration; credentials are never in preferences, exports or skin files (AC-01.02).

This is a confirmed supporting requirement for US-16 through US-21. Resolve a small versioned configuration format, defaults/reset behavior, validation, and compatibility policy alongside those features, not as an unrelated framework.

Implementation: [Versioned preferences](../Sources/LunletDesktop/PreferencesStore.swift), [Tests](../Tests/LunletDesktopTests/PreferencesStoreTests.swift).

## EPIC-06: Keep control of access and application reliability

Outcome: Stop remote access, recover faults and use the app accessibly without exposing private data or leaving background control behind.

### US-12: Stop phone replies, disconnect and quit

Status: Confirmed.

**As a developer, I want to stop phone replies, disconnect my channel or quit Lunlet at any moment, so that I remain in control of remote access to my local sessions.**

Acceptance criteria:

- **AC-12.01**: **Given** phone replies are allowed, **When** I turn the switch off (AC-05.08), **Then** new mobile input is rejected and every issued reply control becomes invalid, while completion notifications and local session monitoring continue.
- **AC-12.02**: **Given** a channel is connected, **When** I disconnect it or switch to another, **Then** its notices can no longer submit actions and its delivery stops.
- **AC-12.03**: **Given** phone replies are allowed again, or a channel is reconnected, **When** continuation becomes available, **Then** only fresh controls targeting revalidated current sessions and requests can submit actions (AC-10.04); earlier controls remain invalid.
- **AC-12.04**: **Given** Lunlet is running, **When** I quit it, **Then** its remote-control connections, owned background operations, and sleep-prevention request are released, its windows and menu-bar entry are removed, and the process exits without leaving unexplained background control.
- **AC-12.05**: **Given** Lunlet is running, **When** I want to stop it, **Then** an explicit Quit action is accessible without scrolling in the panel's Settings page and from its entry context menu; dismissing the panel alone does not quit the application.

Implementation: [setup model](../Sources/LunletDesktop/FeishuSetupModel.swift), [recovery tests](../Tests/LunletDesktopTests/FeishuSetupModelTests.swift), [owner-message client](../Sources/LunletFeishu/BotClient.swift), [transport tests](../Tests/LunletFeishuTests/BotClientTests.swift), [sleep resource](../Sources/LunletDesktop/IdleSleepAssertion.swift).

The [gate](../Sources/LunletCore/ContinuationGate.swift) and [tests](../Tests/LunletCoreTests/ContinuationGateTests.swift) also invalidate old controls across access changes and require fresh session observations before issuing replacements. The [router and its tests](../Tests/LunletFeishuTests/CardActionRouterTests.swift) apply the same boundary to issued forms and delivered message bindings, while preserving controls when access is unchanged. The [socket lifetime tests](../Tests/LunletFeishuTests/FeishuSocketTests.swift) also verify cancellation of an idle native receive and connection-specific invalidation without revoking a replacement connection. The [application runtime](../Sources/LunletDesktop/CompanionRuntime.swift) owns cleanup, and the [application delegate](../Sources/LunletApp/LunletApp.swift) delays termination until cleanup finishes. [Away model tests](../Tests/LunletDesktopTests/AwayModeModelTests.swift) cover overlapping delivery transitions and quit with synthetic resources. The fixed Settings footer and entry context menu expose Quit. Actual pointer interaction and complete live connection shutdown remain unaccepted; process-level quit verification is recorded in feasibility.

### US-14: Diagnose problems without exposing private data

Status: Confirmed. Logging scope: local macOS unified logging plus one bounded local error file (AC-14.07), without diagnostic reports.

**As a developer, I want basic local logs for important operations and failures, so that I can locate problems without exposing my credentials or conversations.**

Acceptance criteria:

- **AC-14.01**: **Given** Lunlet starts, connects, receives or rejects an action, calls Codex, retries, or shuts down, **When** an important diagnostic event occurs, **Then** the macOS system log identifies its component, operation, outcome, and safe error category or code; received, submitted, processing, failed, and uncertain remain distinct.
- **AC-14.02**: **Given** an operation has multiple stages, **When** those stages are logged, **Then** an opaque identifier generated for that diagnostic operation connects them without logging original account, session, request, or message identifiers.
- **AC-14.03**: **Given** logging is active, **When** an event is recorded, **Then** a fixed metadata allowlist excludes credentials, authorization links, signed endpoint tickets, raw HTTP/RPC bodies, provider error text, subprocess output, conversations, prompts, replies, file contents, and identifying filesystem paths.
- **AC-14.06**: **Given** normal operations or error recovery, **When** diagnostics are recorded, **Then** logging adds no network request, and its only application-managed storage is the bounded error file of AC-14.07, does not change authorization or retry decisions, and does not display additional alerts; basic viewing instructions are documented for Console or the system log command.
- **AC-14.07**: **Given** Lunlet runs as the app, **When** a failed or uncertain event is recorded, **Then** the same allowlisted metadata is also appended to a private local file at `~/Library/Logs/Lunlet/lunlet.log` that rotates at 256 KB keeping one previous file, so it never exceeds about 512 KB; it holds no other events, is never uploaded, and Settings › About can show it in Finder. Tests and tools never write it.

Deferred scope, with IDs reserved for later confirmation: `AC-14.04` (custom storage, retention controls, and clearing) and `AC-14.05` (in-app report preparation and export). These are not active acceptance criteria and must not be referenced by first-release code. macOS manages log retention; Lunlet does not automatically upload diagnostics.

Implementation: [typed system logger](../Sources/LunletCore/DiagnosticLog.swift), [opt-in native test](../Tests/LunletCoreTests/DiagnosticLogTests.swift), [continuation receipts](../Sources/LunletCore/ContinuationGate.swift), [Feishu transport](../Sources/LunletFeishu/FeishuConnectionRunner.swift), [Keychain operations](../Sources/LunletFeishu/EnrollmentStore.swift), [Codex account reads](../Sources/LunletCodex/CodexAccountClient.swift), [app lifecycle](../Sources/LunletApp/LunletApp.swift), [power resource](../Sources/LunletDesktop/IdleSleepAssertion.swift), [Viewing instructions](../README.md#development).

### US-24: Use the panel comfortably with a keyboard and assistive tools

Status: Confirmed.

**As a developer, I want keyboard access and readable state cues, so that I can use Lunlet without relying on precise hovering or color perception.**

Acceptance criteria:

- **AC-24.01**: **Given** the panel and its auxiliary chart or connection card, **When** I navigate by keyboard, **Then** focus follows a predictable order and controls can be operated and dismissed without a pointer trap.
- **AC-24.02**: **Given** quota warnings or connection states, **When** color is unavailable or difficult to distinguish, **Then** labels, symbols, and accessibility values still convey the state.
- **AC-24.03**: **Given** the pinned panel is the key window, **When** I press Command-R or Command-comma, **Then** it performs the same global Refresh or opens Settings as the header buttons; while the panel is not key, the shortcuts do nothing and no focus is taken from other applications.
- **AC-24.04**: **Given** the pinned panel is the key window, **When** I press Left or Right, **Then** the choice moves to the neighboring body in the header with a visible focus ring. With Reduce Motion the bodies and the sky change without movement, and percent left is always written beside a body, so no state depends on its lit share or color (AC-24.02).

No global keyboard interception is approved.

Implementation: [panel header](../Sources/LunletDesktop/CompanionPanel.swift), [native check](../Tests/LunletDesktopTests/CompanionPanelControllerTests.swift), [Weekly allowance](../Sources/LunletDesktop/AccountUsageSummary.swift), [The auxiliary controller](../Sources/LunletDesktop/UsageHoverPanelController.swift), [Native tests](../Tests/LunletDesktopTests/UsageHoverPanelTests.swift), [header choice by keyboard](../Sources/LunletDesktop/HeaderLayout.swift), [its tests](../Tests/LunletDesktopTests/HeaderLayoutTests.swift).

### US-25: Keep monitoring lightweight as history and session counts grow

Status: Confirmed.

**As a developer, I want Lunlet to remain responsive and economical in the background, so that monitoring does not slow coding work or unnecessarily consume battery.**

Acceptance criteria:

- **AC-25.01**: **Given** representative idle, active and large-history workloads, **When** Lunlet runs them, **Then** its CPU, memory, disk reads, wakeups and panel-open latency stay within the budgets recorded in [feasibility](feasibility.md#performance-and-resources).
- **AC-25.02**: **Given** cached usage or overlapping refresh requests, **When** refresh completes or fails, **Then** independent sections expose unavailable or incomplete results without fabricating zero usage or blocking unrelated data.

Further cache or scheduling changes require a measured need; no generic provider platform is prebuilt.

Implementation: [Opt-in performance probe](../Tests/LunletDesktopTests/PerformanceBudgetTests.swift), [range-cancellation regressions](../Tests/LunletDesktopTests/LocalUsageModelTests.swift), [Local accounting](../Sources/LunletDesktop/LocalUsageModel.swift), [The chart](../Sources/LunletDesktop/UsageHistoryPanel.swift), [usage scan memory bounds](../Tests/LunletCodexTests/LocalUsageHistoryTests.swift), [session read memory bounds](../Tests/LunletCodexTests/CodexSessionReaderTests.swift), [Claude scan memory bounds](../Tests/LunletClaudeTests/ClaudeSessionMonitorTests.swift).

## EPIC-07: Publish and support a trustworthy product

Outcome: Understand the product, obtain a verifiable release and its usage terms, and optionally support maintenance.

### US-28: Understand Lunlet through a product landing page

Status: Confirmed.

Product page: #film.

**As a prospective user, I want a polished single-page product introduction hosted through GitHub, so that I can understand Lunlet and see how it works before downloading it.**

Acceptance criteria:

- **AC-28.01**: **Given** the product page, **When** I visit it, **Then** it presents the selected Lunlet identity, core benefits, supported capabilities, installation requirements, and a download link to the corresponding GitHub Release.
- **AC-28.02**: **Given** an interaction illustration or demonstration video, **When** it explains the notch, usage, or mobile workflow, **Then** it uses sanitized demonstration content and clearly distinguishes shipped behavior from planned features; product pictures are renders of the real interface with synthetic data, regenerated by script rather than captured from a screen.
- **AC-28.03**: **Given** the free hosting constraint, **When** the page is published, **Then** its hosting and repository visibility are explicitly chosen to fit GitHub Free, and the page remains readable on desktop/mobile and with reduced motion.
- **AC-28.04**: **Given** the README or product page, **When** someone opens it, **Then** a captioned, click-to-play product video uses only synthetic content to explain local observation, usage, locked completion notices and one reply that continues the same session; it never autoplays or implies unaccepted transport behavior, and it shows the real app's notch entry, panel and motion rather than slides.

Implementation: [Product page source](../website/index.html), [native-asset builder](../scripts/build_site.py), [configuration tests](../scripts/test_site.py), [Pages workflow](../.github/workflows/pages.yml), [film render](../Tests/LunletDesktopTests/ProductFilmRenderTests.swift), [script](../scripts/render-film.sh), [MP4](../website/video/lunlet-walkthrough.mp4), [captions](../website/video/lunlet-captions.vtt), [poster](../website/video/lunlet-poster.jpg), [film scenery](../Tests/LunletDesktopTests/ProductFilmScenery.swift), [still render](../Tests/LunletDesktopTests/SiteAssetRenderTests.swift), [still script](../scripts/render-site-assets.sh), [render manifest check](../scripts/check_site_assets.py).

### US-27: Download a versioned macOS release from GitHub

Status: Confirmed. Owner decision 2026-11-01: the first downloadable release is an unsigned preview (an ad hoc-signed app in a disk image, with a ZIP for the update feed), because Developer ID signing and notarization require a paid Apple Developer Program membership, which the project does not have; a signed, notarized release remains the later path. `v0.1.0` shipped this way on 2026-11-01, `v0.2.0` and `v0.2.1` on 2026-11-14.

Product page: #availability.

**As a developer, I want a clearly versioned Lunlet download on GitHub, so that I can install and update it without compiling the source myself.**

Acceptance criteria:

- **AC-27.01**: **Given** an owner-approved release, **When** I open its GitHub Release, **Then** I can find the macOS download, release notes, minimum OS and architecture requirements, and artifact checksums for the matching source tag.
- **AC-27.02**: **Given** the owner's GitHub Free cost constraint, **When** release automation is designed, **Then** it uses a documented free-compatible path with explicit repository visibility, runner, storage, and budget assumptions; it does not silently require a paid service.
- **AC-27.03**: **Given** a distribution candidate, **When** it is prepared for publication, **Then** automated checks, clean packaging, the signing and notarization status, and an install of the candidate's own image on a Mac are reviewed before publication, and from the second version a real in-app update on a clean Mac (AC-35.02). Development previews are not presented as public releases, and an unsigned preview package is never presented as signed or notarized.
- **AC-27.04**: **Given** a period without a downloadable package (as before `v0.1.0`, or after a withdrawn release), **When** the repository is public, **Then** the README, product page and release status label it as source-only, omit a binary download, identify unaccepted behavior, and retain a separate path to a later GitHub Release.
- **AC-27.05**: **Given** an unsigned preview release, **When** I read its GitHub Release or the product page, **Then** both say that macOS asks to allow the app on first open and name the steps (System Settings › Privacy & Security › Open Anyway on macOS 15 and later; right-click › Open before that), and never call it notarized; an update asks for nothing, because credentials live in Lunlet's user-only file rather than the Keychain (AC-01.02); the packaged manifest records ad hoc signing and no notarization, and a signed, notarized release later replaces these notes.

Implementation: [README status and install steps](../README.md), release notes for [v0.1.0](release-notes/v0.1.0.md), [v0.2.0](release-notes/v0.2.0.md), [v0.2.1](release-notes/v0.2.1.md) and [v0.2.2](release-notes/v0.2.2.md), [validation workflow](../.github/workflows/validate.yml), [candidate packager](../scripts/package-release.sh) with its unsigned preview mode, [application build](../scripts/build-app.sh), [release guide](releases.md), [product page availability copy](../website/index.html), [release boundary tests](../scripts/test_release.py).

### US-29: Understand the project's license and third-party provenance

Status: Confirmed.

**As a user or contributor, I want clear license, copyright, and third-party attribution information, so that I can understand the terms for using and contributing to Lunlet.**

Acceptance criteria:

- **AC-29.01**: **Given** the first public release, **When** the repository and package are prepared, **Then** the owner-approved project license, actual copyright holder, and open-source description are consistent and available; free-of-charge distribution is not treated as a substitute for license review.
- **AC-29.02**: **Given** tracked files, **When** licensing metadata is added, **Then** project-owned source has the chosen license identifier and approved copyright marking in an appropriate header. Generated or reused files retain upstream notices; formats that cannot accept comments, including binary artwork, receive appropriate external licensing metadata rather than corrupting files or claiming upstream ownership.
- **AC-29.03**: **Given** dependencies, generated code, artwork, fonts, and product references, **When** release review occurs, **Then** an inventory records origin, version, license, modifications/reuse, required notices, and unresolved permissions. Required notices accompany the source and distributed package as applicable.
- **AC-29.04**: **Given** a competing product used as inspiration, **When** acknowledgments are written, **Then** they distinguish conceptual reference from copied or adapted material and do not imply endorsement. A thank-you does not replace required authorization or notices.
- **AC-29.05**: **Given** Settings › About, **When** I open it, **Then** it shows the lun·let lettering with the version and build, a one-line description, the developer (yukunlabs), the open-source license (0BSD, free for everyone), a short privacy summary (runs on this Mac with no analytics, credentials in a file only my user can read and sealed for this Mac, notices only to the channel I set up), bundled third-party software with its license, and the copyright line, all on one page of the panel without scrolling.

Implementation: [The provenance inventory](../NOTICE.md), [0BSD LICENSE](../LICENSE), [The traceability check](../scripts/check_traceability.py), [tested](../scripts/test_traceability.py), [About page](../Sources/LunletDesktop/PreferencesPane.swift).

### US-30: Optionally support project maintenance

Status: Confirmed.

**As a user who values Lunlet, I want an optional way to support its maintenance, so that I can contribute financially without changing access to its free functionality.**

Acceptance criteria:

- **AC-30.01**: **Given** an owner-approved support link, **When** I view the repository or product page, **Then** an unobtrusive secondary link labeled "Buy me a coffee" lets me voluntarily open an external support page, without a prominent fundraising block, payment prompt in the coding workflow, or feature paywall.
- **AC-30.02**: **Given** no selected donation provider or recipient account, **When** Lunlet is published, **Then** support remains optional and no placeholder payment destination, financial commitment, or unverified eligibility claim is published.
- **AC-30.03**: **Given** the support entry, **When** I have not followed its link, **Then** the product page and repository do not display collection QR codes, payment-account details, or a list of payment methods. Those details, if used, belong on the linked support page.
- **AC-30.04**: **Given** approved support destinations for mainland China and overseas supporters, **When** I open the optional support page, **Then** each offered route leads to a verified recipient and supported checkout method; unavailable routes, placeholder accounts and unapproved crypto addresses are not published.

Implementation: [product page](../website/index.html), [Configuration tests](../scripts/test_site.py).

### US-34: Contribute through a clear review process

Status: Confirmed. Depends on US-27 for repository publication, US-29 for licensing and provenance, and the story approval rules for application changes.

**As a contributor, I want clear issue and pull request requirements, so that I can propose a useful change and know how it will be reviewed.**

Acceptance criteria:

- **AC-34.01**: **Given** a public repository, **When** I open an Issue, **Then** bug and feature forms ask for reproducible behavior or a user outcome, supported versions and sanitized evidence as relevant, and direct security reports to a private channel rather than a public Issue.
- **AC-34.02**: **Given** a pull request, **When** I submit it for review, **Then** the template asks for the confirmed story and criterion IDs, affected behavior, focused tests and manual acceptance gaps, privacy and third-party material checks, and release-document impact; unconfirmed behavior is not merged as an implementation detail.
- **AC-34.03**: **Given** the public default branch, **When** a contribution is merged, **Then** the repository requires its validation check and resolved review conversations, disallows force pushes and deletions, and has a maintainer review policy that works with one maintainer; adding a mandatory independent approval waits until another reviewer is available.

Implementation: [contribution guide](../CONTRIBUTING.md), [bug](../.github/ISSUE_TEMPLATE/bug.yml), [feature](../.github/ISSUE_TEMPLATE/feature.yml), [Issue configuration](../.github/ISSUE_TEMPLATE/config.yml), [PR template](../.github/pull_request_template.md).

### US-35: Learn about and install updates

Status: Confirmed. Sparkle 2 with automatic checks and installation only after a click. Depends on US-27 for published releases and their destinations, and on US-29 for third-party notices.

**As a Lunlet user, I want to learn that a new version is available and install it with one click, so that I stay current without visiting a website or reinstalling by hand.**

Acceptance criteria:

- **AC-35.01**: **Given** a release build with a configured update feed, **When** Lunlet starts and about once a day while it runs, **Then** it checks the feed in the background, sending only what the update framework needs (the app and macOS versions), and when a newer version exists it shows a small notice in the panel footer without interrupting work; nothing is downloaded or installed before I act.
- **AC-35.02**: **Given** the notice or Settings › About › Check for Updates…, **When** I choose to update, **Then** I see the new version and its release notes, and installing downloads it, verifies the update's signature (and, for a Developer ID-signed release, its code signature), replaces Lunlet and relaunches it with my settings, skins and saved bot authorization intact without any prompt (AC-01.02); a failure leaves the installed version unchanged and says so.
- **AC-35.03**: **Given** Settings › About, **When** I open it, **Then** it offers Check for Updates… and a switch for automatic checks, on by default; turning it off stops background checks, and a manual check still works.
- **AC-35.04**: **Given** a development preview or a build without a configured feed and update key, **When** it runs, **Then** it performs no update checks and shows no update controls, so a preview never offers to replace itself.

Implementation: [package manifest](../Package.swift), [license](../Resources/third-party/sparkle-license.txt), [provenance inventory](../NOTICE.md), [The updater](../Sources/LunletDesktop/AppUpdater.swift), [panel footer](../Sources/LunletDesktop/CompanionPanel.swift), [About](../Sources/LunletDesktop/PreferencesPane.swift), [Info.plist](../Resources/Info.plist), [Packaging](../scripts/build-app.sh), [Unit tests](../Tests/LunletDesktopTests/AppUpdaterTests.swift), [release tests](../scripts/test_release.py), [update feed check](../scripts/check_appcast.py) with [its tests](../scripts/test_appcast.py), [update rehearsal](../scripts/rehearse_update.py) with [its tests](../scripts/test_rehearse_update.py), [render harness](../Tests/LunletDesktopTests/PanelPageRenderTests.swift), [Release preparation](releases.md#updates-with-sparkle).

## Release acceptance

The source and the unsigned previews `v0.1.0`, `v0.2.0` and `v0.2.1` are published (AC-27.05); a signed, notarized package and full mobile continuation keep their own gates below. The product page and video may demonstrate shipped local behavior with synthetic data while naming any channel delivery or reply behavior that is not yet accepted.

The first release is ready when the stories applicable to the declared release scope pass in the recorded macOS, Codex and Claude Code versions. Confirmation alone is not acceptance; Cursor, Claude phone replies and optional support do not become first-release gates. Record the reference terminal environments used for verification without making terminal brands a capability allowlist. Verification must cover at least two concurrent sessions, two sessions in the same project, continued context over multiple turns, local task cues with and without full-continuation access, display sleep and lock behavior, lock-screen mobile interaction, approval isolation, duplicate and stale actions, enabling full-continuation access with already-pending work, disabling and re-enabling mobile access, unavailable channel setup or connectivity, disconnection, session exit and restore, and quitting Lunlet. The Settings switch in AC-05.08 and AC-05.09 governs phone replies; screen locking alone does not authorize input.

Before each binary release, review the provenance inventory of US-29 for new material and the distribution decisions of US-27; the 0BSD license and copyright identity are selected, and their presence does not waive that review. No publication authorizes paid enrollment or a support destination.

Acceptance also covers the confirmed scope expansions: CLI, Codex App, editor, execution and child-session observation; Claude Code phase A observation and usage; default and exposed custom accounting roots; same-UUID copies across roots/archives; new activity after Clear; History membership controlled by Clear; unknown state/pricing; selected one-to-seven-day Token/Cost ranges; notch/menu-bar exclusivity; and Feishu authorization/owner binding and Slack/Telegram private pairing, plus all three channels' cancellation, channel switching and uncertain-send behavior. Feishu, Telegram and Slack delivery and one reply per notice are verified live (see [feasibility](feasibility.md#messaging-channels)). Keep observation, original-app navigation, notification delivery and original-CLI input as separate acceptance results. Full mobile continuation cannot pass until the question answer path (US-07) is built and validated alongside the verified follow-up path; the Settings activation rule is already confirmed under AC-05.08 and AC-05.09.

Record reproducible steps, observed results, supported versions, and failure boundaries in [the feasibility notes](feasibility.md). The developer must be able to start work on the Mac, step away, receive useful summaries, answer an ordinary question or send a follow-up to the correct existing session, and understand the outcome without maintaining a separate agent platform.
