# Feasibility

Checked against Codex CLI 0.166.0 (behavioral experiments also on 0.163.0–0.164.0), Claude Code 2.1.314, Apple Swift 6.4 and macOS 27.

Current state: partial MVP. Client-independent local Codex observation, Claude Code observation, account limits and local usage, native presentation and customization, scan-based Feishu authorization, Slack and Telegram pairing, locked-device completion delivery and replies that continue the same Codex session are implemented. Live, owner-run acceptance exists for Feishu, Telegram and Slack delivery and replies; most other acceptance is synthetic or pending on the device.

This document is organized by domain. Each domain states what is implemented, what has been verified and how, and what remains open. Record new evidence by updating the owning domain's Verified and Open gates lists in the present tense; keep results reproducible and never record message content, credentials or callback payloads.

Validation order: (1) terminal-independent identification and continuation of existing Codex CLI sessions, comparing [queue](https://learn.chatgpt.com/docs/cli/reference#codex-queue), [hooks](https://learn.chatgpt.com/docs/cli/hooks) and the [app-server protocol](https://learn.chatgpt.com/docs/app-server); (2) Feishu authorization, delivery and callbacks; (3) native presentation; (4) packaging and release.

| Domain | Current state | Main open gate |
|---|---|---|
| [Codex session observation](#codex-session-observation) | Read-only, client-independent native observation; activity separate from liveness and input authority | Question/approval classification; original VS Code and Codex App device acceptance |
| [Claude Code observation](#claude-code-observation) | Phase A and status-line plan limits implemented; synthetic evidence plus one live status-line reading | Owner-assisted live session, usage and locked-delivery checks |
| [Original-CLI continuation](#original-cli-continuation) | Gated `codex queue` follow-ups from the completion card, verified live end to end | Mobile rendering, refusal paths and the approval challenge live |
| [Destination navigation](#destination-navigation) | Superset/iTerm reveal only for separately resolved, revalidated destinations | Real double-click/reveal acceptance; shared-runtime original-client mapping |
| [Account limits and local usage](#account-limits-and-local-usage) | Automatic account reads, bounded local history, estimated costs and weekly trend | Live account-read source, freshness and overhead acceptance |
| [Messaging channels](#messaging-channels) | Feishu authorization, delivery, callbacks and in-place card updates verified live; Telegram and Slack pairing, locked delivery and a reply that continued the session verified live | Feishu card review in the phone app |
| [Locked-device notifications and power](#locked-device-notifications-and-power) | Locked completion delivery with an owned idle-sleep assertion, owner-confirmed | Long-running lock/wake, display sleep and full lifecycle checks |
| [Desktop interface](#desktop-interface) | Native notch/menu entry, panel, cues, Settings, skins and colors with native-window tests | Physical pointer, focus, appearance and multi-display acceptance |
| [Diagnostics, signing and credential storage](#diagnostics-signing-and-credential-storage) | Minimal unified logging; signature-gated Keychain access; previews re-own the saved item after authorization | Credential continuity across Developer ID-signed updates |
| [Performance and resources](#performance-and-resources) | Opt-in synthetic probe within engineering targets | Real-discovery, uncached, signed full-app energy and responsiveness |
| [Release preparation and repository hygiene](#release-preparation-and-repository-hygiene) | Source published; CI, packaging (including the unsigned preview mode), product page and provenance prepared; no download yet | Clean-machine installation and release decisions; signing/notarization deferred by owner decision |

## Codex session observation

### Current state

- Read-only, client-independent observation is wired into the runtime (US-02 / AC-02.01–08; US-04 / AC-04.02, AC-04.08, AC-04.11) and covers Codex App, editor clients, noninteractive tasks and child agents; Desktop exclusions apply to input, not observation. It requires exact same-user Codex process identity, a writable vnode and the rollout UUID; one shared runtime may own multiple distinct root sessions. Source labels are not client identity, and noninteractive or runtime-owned records are observation-only.
- Activity, original-client liveness, navigation and mobile-input authority are separate facts. [Snapshots](../Sources/LunletCore/SessionSnapshot.swift) carry them separately and [discovery](../Sources/LunletCodex/CodexSessionMonitor.swift) is not restricted to terminal brands; identity and lifecycle remain Codex-specific. Observations grant no mobile capability.
- Actual turn/input records determine Active/History; discovery and recovery never invent a completion or replay cues. Codex's marked runtime-context records are not user input. Pending question/approval classification is not implemented. Ambiguous owners, inaccessible records and shared-service-only sessions remain unverified; only records exposed on this Mac by the current user are covered.
- No hooks, launch changes or Codex configuration changes are used.

### Verified

- Synthetic regressions in `scripts/test-core.sh codex` cover discovery, binding, terminal attachment without a controlling-terminal flag, the first `session_meta` record as canonical, sub-agents named only by top-level `payload.parent_thread_id`, every 0.166.0 tool command and alias, `--local-provider` and multi-value `-i/--image`, runtime-context filtering and bounded scans (about one event-driven scan per second).
- Read-only default-daemon discovery is proven for a dedicated interactive CLI in this environment; no Codex configuration is changed, no session is started or resumed and no credential is read.

### Open gates

- Pending question and approval classification (AC-02.03, AC-02.05) is not implemented; no state is inferred.
- Original-client lifetime cannot be derived from loaded state, creation provenance, source labels or file freshness; see [Original-CLI continuation](#original-cli-continuation).
- Physical acceptance of the Codex App list and usage, the original VS Code instance's Active/History placement, and live confirmation that sub-agent rows no longer appear separately.
- Fork canonical-record handling is unverified against 0.164.0; fork usage separation is open.
- If `token_count` is ever dropped in favor of `token_usage_record`, local accounting must move with it.

## Claude Code observation

### Current state

- Phase A is implemented (US-33 / AC-33.01–07, AC-33.11; revised AC-19.01): read-only session observation, recorded local usage with API list-price estimates, locked completion notifications, the account email and plan from Claude Code's own configuration file, and the multi-provider Overview. Phone replies for Claude remain later work.
- Binding uses Claude's own per-process registry: a same-user live process whose libproc start time matches `procStart` within one second and whose executable is Claude Code, plus an exact `<sessionId>.jsonl` transcript. Stale records are ignored, two live owners keep a session ambiguous and observation-only, and the proven owner is never treated as original-client liveness, so no input authority exists.
- Plan limits have no credential-free local source; Lunlet connects its own status line automatically while Claude Code is selected (AC-33.08), which then reports Claude Code's five-hour and weekly percent used, and Settings › Agents can disconnect it for good.

### Verified

- Synthetic regressions in `scripts/test-core.sh claude` cover the registry, transcript reader, usage reader, pricing, status-line connection and account profile; the owner's real `~/.claude.json` is never touched by tests.
- Real status-line readings for both windows arrived on the owner's Mac after connecting (values not recorded).

### Open gates

- Owner-assisted dedicated sessions: `-p` with and without `--bare`, an SDK run, background or agent-view sessions, `/clear`, `--resume`, `--fork-session`, one session in two terminals, a crash leaving a stale registry file, exit mid-turn, a permission prompt and an input wait, an interrupt and a compaction; `claude agents --json` compared with the registry; whether `turn_duration` appears without third-party hooks; npm-installed executables; projects whose encoded directory exceeds 200 characters; usage reconciled against `/usage` or the status line; locked-device delivery of a Claude completion; on-device Overview and Claude page acceptance.
- Status line: reading age across idle sessions; the footer with Lunlet's line alone and chained after an existing line; how Claude Code runs the command (Lunlet chains through `/bin/sh -c`) and reloads a changed `statusLine`; workspace trust, `disableAllHooks`, managed or project `statusLine` overrides; the five-hour window's reset behavior; readings from a second account on this Mac, which the status line does not identify; forecast accuracy over a real week. The status line carries no account field; the account comes from `oauthAccount` in Claude Code's configuration file, read as email, organization type and rate-limit tier only.
- Background overhead of tailing fast-growing transcripts with megabyte lines and of the five-second registry poll.

## Original-CLI continuation

### Current state

- While the Mac is locked, an eligible Codex completion card ends with a reply box bound to one single-use capability, and the callback connection runs only while such a card is valid. A reply is handed to the same running CLI with `codex queue --thread <uuid> --message <text>` through the observed process's own executable with a fixed PATH; queue acceptance is only a submission receipt, so the live binding is rechecked first and arrival is confirmed from that session's record. Card-only input is the rule (US-07 / AC-07.05, US-08 / AC-08.05); ordinary bot messages are not an input source. Claude Code stays notification-only.
- The replied card is updated in place through Feishu's message-update API: received, sent to Codex, then the outcome; a refused update falls back to a separate receipt card. Open boxes close in place when the Mac unlocks, when the control's lifetime ends or when a newer card for the same session replaces them. The first card after a new enrollment is sent without a box and gains it in place once its own receipt has verified the owner.
- The fail-closed [continuation core](../Sources/LunletCore/ContinuationGate.swift) rejects unverified evidence. Locking authorizes no input by itself: every reply passes the owner, message, freshness, single-use and live-binding checks. The launch-path setup in [requirements](requirements.md#proposed-codex-setup-constraint) is Proposed and not accepted.

### Verified

- Live, owner-run, no message content recorded: a reply typed on the Feishu card reached the same running Codex session as a new turn under its existing sandbox and approval policy, with no second session; `card.action.trigger` arrived on the long connection of a scan-created app without console configuration; the replied card greyed out and showed received, sent and delivered in place; the session's next card arrived with its own box; unlocking closed that box in place; and after a fresh scan the first card gained its box in place and took a reply.
- Dedicated synthetic sessions on 0.163.0–0.166.0: UUID-targeted `codex queue` follow-ups retain context, isolation and approval/sandbox policy.
- Synthetic regressions: `scripts/test-core.sh core` (gate, refusal classification, reply-text rules, control withdrawal), `feishu` (router, coordinator, reply service, card rendering) and `desktop` (the phone-reply flow against a synthetic CLI and queue, in-place updates and fallbacks).
- Provider behavior established with synthetic cards: an input that is both `required` and `disabled` is refused (230099, sub-code 10002); `interactive_container` is accepted without `behaviors`; `column.background_style` and a body `vertical_spacing` render; updates need `config.update_multi` before and after and stay well under the five updates per second per message.

### Open gates

- Unexplained: after each bot message delivered while the callback connection is open, the router rejects one inbound frame as malformed one to seven seconds later. The frames are acknowledged and nothing else is affected; the frame type is not logged, so the source is unknown (one hypothesis is read-receipt events).
- Live acceptance pending: the look of each in-place state in the Feishu phone app; expiry and supersession of a delivered card; refusals for a running or ended session; a write request that still blocks on the Mac after a phone reply; the execution-approval challenge through the mobile path; question provenance (a pending native question had no matching public thread item).
- A card whose send is cancelled by unlocking while Feishu still delivers it has no message ID, so its box cannot be closed in place; a tap on it meets the closed reply window.
- Residual risks: `codex queue` accepts ended sessions, so an unconfirmed reply may stay queued and run when that session is next resumed, and Lunlet cannot withdraw it; the reply text is a process argument visible to other processes of the same user; a revoked card answers accurately only while its connection is open.
- Open owner decision: whether the ten-minute control lifetime should still apply in addition to the unlock rule (AC-05.09).
- Not built: the AC-05.08 Settings switch and AC-05.02 initial-state cards.

## Destination navigation

### Current state

- Optional double-click and keyboard navigation reveals the original host only when a destination is separately resolved and revalidated (US-03 / AC-03.01–03). It is independent of discovery, monitoring, liveness and remote-input authority, defaults to unavailable, and never opens a default terminal, generic URL handler or shell, resumes a Codex session or sends input.
- [Destination detection](../Sources/LunletCodex/CodexDestinationReader.swift) supports Superset and iTerm; the [opener](../Sources/LunletDesktop/SessionDestinationOpener.swift) accepts an application URL; the [Superset binding reader](../Sources/LunletCodex/SupersetSessionBindingReader.swift) uses a private database schema and fails closed on symbolic links, unreadable databases, duplicate bindings and oversized discovery, while an organization without a database holds no binding. These are limited implementations, not general navigation.

### Verified

- Synthetic regressions in `scripts/test-core.sh codex` and `desktop`; no reveal link has been opened during validation.

### Open gates

- Real double-click acceptance against the owner's client; iTerm has synthetic evidence only; physical focus behavior is unaccepted.
- Shared-runtime original-client mapping (AC-03.02/03) and original-daemon-to-terminal navigation are unresolved.

## Account limits and local usage

### Current state

- Account limits are read automatically through an owned, bounded stdio app-server (`initialize`, `account/rateLimits/read` and `account/read`): once at startup, on panel openings no more than once per five monotonic minutes (including failures), and on explicit or global Refresh. There is no background polling timer. Package-manager `codex` launchers are found in a bounded set of user install directories without running a login shell.
- Account quota, session usage, earned-reset entitlements and estimates stay separate; unknown values stay unknown, and no plan multiplier, credit currency or reset schedule is fabricated. When several buckets report a seven-day window, weekly allowance uses the default `codex` bucket, as credits do.
- Local usage comes from bounded, read-only rollout accounting across selected/default and process-discovered roots, with estimated USD at published standard rates; incomplete costs are labeled `≥` and unpriced usage stays unavailable. One-to-seven-day history ranges (US-18) and the weekly trend with a labeled pace estimate (US-32) estimate a range from full-resolution readings independent of the displayed range.
- [Account limits](../Sources/LunletCore/AccountLimits.swift) and [local accounting](../Sources/LunletCodex/LocalUsageHistory.swift) are Codex-specific; Claude has its own [recorded-usage reader](../Sources/LunletClaude/ClaudeLocalUsageReader.swift) and no account-limit source. The Overview shows each provider separately; no cross-agent allowance or usage total is computed.

### Verified

- Synthetic regressions in `scripts/test-core.sh codex` and `desktop` cover the account client, presentation, bounded history, resumption of appended rollouts by file identity, the trend's reset-drift tolerance and the forecast backtest.

### Open gates

- A real account-limit read with verified source, freshness, unknown fields and overhead; live npm/nvm Codex account reads.
- Live pacing accuracy (US-32): predicted ranges and run-out times against the observed remaining at reset over at least one real weekly window; physical presentation acceptance.
- Previously unseen custom roots cannot be inferred after a task exits; fork usage stays partial.

## Messaging channels

### Current state

- One user-owned channel is selected: Feishu/Lark, Slack or Telegram (US-20). [Slack and Telegram](../Sources/LunletMessaging/BotTypes.swift) share a client protocol; Feishu has separate registration and owner identity. Shared notifications do not establish shared bidirectional control.
- Feishu scan-based registration, owner-bound notification delivery, the long-connection callback transport, callback decoding and routing, the mobile coordinator and in-place card updates are wired through the [reply service](../Sources/LunletFeishu/FeishuReplyService.swift). The owner tenant is learned from the first verified send receipt, kept with the enrollment and never established by callbacks.
- Slack and Telegram pair an expiring private chat and, like Feishu, take one reply per eligible notice through the shared [reply service](../Sources/LunletMessaging/BotReplyService.swift): Telegram long-polls `getUpdates` for the owner's reply to the notice and edits the notice with `editMessageText`; Slack listens on Socket Mode for the owner's message in the notice's thread and rewrites the notice with `chat.update`. Both run only while a notice is within its validity period and reuse the continuation gate.
- Readiness separates authorization, completion delivery, card replies and session input; a successful notification never implies callback or CLI-input readiness.
- [`EnrollmentStore`](../Sources/LunletFeishu/EnrollmentStore.swift) uses the macOS file-based Keychain with an exact service/account query, no synchronization and no plaintext fallback; no Keychain access-group entitlement is assumed (see Apple's [macOS Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)). The opt-in `LUNLET_TEST_KEYCHAIN=1 scripts/test-core.sh` test writes synthetic credentials only.
- Dependency: Apple [SwiftProtobuf 1.39.0](https://github.com/apple/swift-protobuf/tree/3d537cb81aef272a03cb3be815439e9bf0eb3bd3), exact commit `3d537cb81aef272a03cb3be815439e9bf0eb3bd3`, Apache 2.0 with Runtime Library Exception; protoc tools are build-time only, and `scripts/generate-feishu-protocol.sh` regenerates the internal messages from their declared schema.

### Verified

- Live, owner-run: scan-based registration of a new or existing Feishu app, owner-bound delivery to a locked Mac, callback delivery on the long connection without console configuration, and in-place card updates through `PATCH /open-apis/im/v1/messages/:message_id` with the `im:message:send_as_bot` scope.
- Synthetic regressions in `scripts/test-core.sh feishu` and `messaging` cover registration, the HTTP client, card rendering and decoding, the router, the frame/discovery/socket/runner layers, Slack/Telegram pairing, reply reception (only the paired owner's fresh reply to the bot's own notice), in-place edits and the bot reply service's gates, states, expiry and fallbacks.
- Live, owner-run: a Telegram bot token entered in the setup card was accepted by Telegram, the private chat paired with the expiring code, a Codex completion reached the paired chat 13 s after the Mac locked with the heading, request quote and reply as designed while the idle-sleep assertion was taken at the lock and released at the unlock, and a reply sent from the notice's Reply button on the locked Mac was rewritten through Received, Sent and Delivered within 9 s while the same Codex session ran it as its next turn, whose own notice arrived 14 s later and was rewritten as Replies closed on unlock.
- Live, owner-run: a Slack app created from the manifest link was connected and its direct message paired with the code; a Codex completion reached it 11 s after the lock, the owner's thread reply was rewritten through Received, Sent and Delivered within 8 s while the same session ran it, the next turn's notice arrived 13 s later and unlocking rewrote it as Replies closed.

### Open gates

- Feishu card review in the phone app, including each in-place reply state.
- Quit stalled twice on 2026-11-01 (01:15 and 01:24 local) while a Slack reply listener was active; the system log holds `event=shutdown outcome=started` for each with no stage or completion entry. Both ran a build from before the Socket Mode receive was made to resume on cancellation; every quit since completed within 100 ms. Each shutdown stage now waits at most two seconds and logs `uncertain reason=timeout code=<stage>` when it overruns, and the eight-second watchdog remains. Root cause probable, unproven: pending an owner reproduction with an active Slack listener.
- Behavior under organization restrictions and the three-second provider response budget under load.

## Locked-device notifications and power

### Current state

- While the Mac is confirmed locked, saved owner enrollment delivers new verified completions (US-05 / AC-05.04–06; US-06 / AC-06.01–05; US-01 / AC-01.08; US-12 / AC-12.02, AC-12.04). A notice carries the outcome, project, agent and session, a request excerpt and the agent's final reply cut only at the channel's limit; Feishu cards follow Feishu's card conventions; Slack and Telegram notices carry no footer because those channels show the time themselves. Startup/recovery snapshots and duplicate turns are suppressed; failed or uncertain sends are visible and not retried.
- An owned idle-system-sleep assertion is held during that path and released on unlock, disconnect or quit; display sleep is allowed and power preferences are never changed. A newly configured sender is checked once without sending a message.
- There is no main-panel Away Mode switch. Lock state comes from the I/O registry root `IOConsoleLocked`, a private-schema key.

### Verified

- Live, owner-run: Codex completion cards delivered to the locked Mac's paired Feishu chat, rendered as designed on Feishu desktop and accepted by the owner; a Codex completion delivered to the paired Telegram chat while locked, rendered as designed in the Telegram app; a Codex completion delivered to the paired Slack direct message while locked and answered from its thread in the Slack app.
- Opt-in `LUNLET_TEST_POWER=1` checks: exactly one owned `PreventUserIdleSystemSleep` assertion after duplicate enables, none after duplicate disables, no display-sleep assertion; `scripts/test-core.sh desktop` covers lock gating, baseline and duplicate suppression, visible delivery failure and cleanup.

### Open gates

- Owner review of the Feishu card in the phone app.
- On the Mac: no cue while locked or asleep, no replay on return, display sleep, idle-sleep prevention and release, and that normal and OS-requested quit leave no owned child, socket or power assertion.
- Long-running lock/wake, lid-close, explicit sleep and network interruption; `IOConsoleLocked` behavior on older deployment targets.
- The AC-05.08 Settings switch and AC-05.02 initial-state controls.

## Desktop interface

### Current state

- A native AppKit/SwiftUI shell provides a notch entry (connected lun / let lettering with an allowance vine, or lanterns) and an exclusive menu-bar fallback with a monochrome wordmark; one reusable owned panel centered at the screen top with frosted glass, concave shoulders and the header in the notch band; non-key, non-activating black task-cue islands; and categorized native Settings with Vine and Lantern skins, validated declarative custom skins and per-skin color controls. With both agents selected, the vine twists two strands and the lantern skin hangs two crossing cords.
- [Runtime assembly](../Sources/LunletDesktop/CompanionRuntime.swift) directly wires Codex, Claude Code and each channel; [custom skins](../Sources/LunletDesktop/SkinCatalog.swift) use constrained paths and two render types, not arbitrary plugins.

### Verified

- Native window tests (`LUNLET_TEST_PANEL=1 scripts/test-core.sh desktop`; they fail while the screen is locked because windows cannot become key), offscreen panel renders (`LUNLET_RENDER_DIR`), the completion-notice preview (`LUNLET_NOTICE_PREVIEW_DIR`) and the product-film scenery render pass; every build passes strict signature verification and a normal quit leaves no owned process.
- Owner on-device reviews accepted the native vine entry, the macOS-style panel redesign, the task-cue island and the Feishu card layout as the current baseline.

### Open gates

- Physical pointer routing, keyboard/focus behavior, rendered notch and frosted-glass appearance, menu overlap, full-screen spaces, animation quality, notch and external-display placement, and no-notch displays.
- Owner visual acceptance of skins, colors, controls and Settings, the two-cord lantern skin, the glass surface, shoulders, header band, spring timing and segmented switches; physical pointer/keyboard comfort of the color controls; hover, retraction and Escape behavior, both context menus and badge colors across appearances.

## Diagnostics, signing and credential storage

### Current state

- Diagnostics use native macOS unified logging under subsystem `com.lunlet`, with typed metadata and no arbitrary strings, plus the bounded local error file of AC-14.07; there are no clear controls, report export or telemetry (US-14). A refused reply logs `sessionInput rejected` with the refusal's reason and the refusing stage; a live-binding refusal also logs `sessionBinding rejected` naming the failed check, and a live session that becomes unverifiable logs `sessionObservation uncertain`.
- Credentials live in `~/Library/Application Support/com.lunlet/credentials/<service>.json`, one file per former Keychain service, in a directory created with mode 0700 and files written with mode 0600 from their first byte and moved into place atomically; a file found wider than user-only is narrowed before it is read, and files over 64 KB are refused. Decided on 2026-11-01 so that updates of an unsigned build never ask for authorization (see the spike below). Any process running as the user can read these files, as it can read Codex's own credential file.
- Bundle, signing and log identifiers use `com.lunlet`. The Keychain store remains in the code for a later signed release and as the source of credentials saved before the file: on first use they are moved into the file, silently when the build may still read them and otherwise through Authorize access once, and the Keychain item is then removed. New Keychain writes, when that store is used, go to `com.lunlet.feishu`; the previous service string is used only for fallback reads and explicit removal.
- The store checks its own signature before any credential operation and uses a serialized, scoped legacy no-interaction policy. Normal builds require `LUNLET_CODE_SIGN_IDENTITY`; previews may be signed with a local development certificate or ad hoc, read silently and prompt only from the owner's Authorize access action, after which the saved item is re-created under the running build so relaunches of that binary stay silent.

### Verified

- The Keychain identifies a preview by its binary even when it is signed with a self-signed certificate trusted in the user domain: a rebuild with changed code is refused (-25293) until the owner authorizes once, while relaunching the same binary after authorization reads silently. `securityd` evaluates the signer against the admin trust domain, so a user-trusted self-signed certificate does not give cross-build continuity.
- Trusted-application access lists do not hand an item over between ad hoc builds (spike of 2026-11-01 with three ad hoc-signed binaries sharing one identifier, outside the repository): an item one binary created with another listed as a trusted application, or with every application allowed on every ACL, was still refused to the other binary with -25293, because securityd pins the item's partition list to its creator's code hash (`cdhash:<hash>`), which the application list does not override. Rewriting that partition list on the item, or supplying one at creation, needs the keychain owner's authority: both calls blocked on a prompt despite disabled interaction, and the item then refused even its creator until `security delete-generic-password` removed it. There is no silent hand-over between unsigned builds; an unsigned release keeps one authorization click per update, and only a stable certificate identity removes it.
- `scripts/test-core.sh storage|feishu|messaging` cover silent reads, no automatic prompt or retry, policy restoration, re-owning after authorization and credential removal with injected Keychain APIs; the opt-in `LUNLET_TEST_KEYCHAIN=1` test uses synthetic credentials.

### Open gates

- Credential continuity across a real update on a clean Mac now means the credential file surviving the update untouched, which the clean-machine update test confirms. Keychain continuity across two Developer ID-signed versions, and the data-protection keychain with an access group, are evaluated only if a signed release returns to the Keychain store.
- Opt-in diagnostics checks on the device.

## Performance and resources

### Current state

- An explicitly enabled, opt-in debug probe measures synthetic workloads against recorded engineering targets (US-25 / AC-25.01, AC-25.02); the latest sample met them and justified no optimization. It is not part of the routine edit loop.
- Observation runs on utility-priority executors and is event-driven with a restrained discovery sweep; account reads are throttled; there is no background polling timer.

### Verified

- Latest synthetic probe (debug build): 200-session cold observation 63 ms CPU, 20 completions 9 ms, 12 s idle 15.5 ms with 5 wakeups, cold 1,000-file history 2.1 s CPU; one run each, not statistically established.

### Open gates

- Signed real-app lock/wake, actual discovery and physical responsiveness; uncached full-app CPU, memory, disk, wakeup and latency; idle and active monitoring overhead with the callback connection open; resource measurements for per-record reads, scan throttling and usage resumption under AC-25.01.

## Release preparation and repository hygiene

### Current state

- The source is published at https://github.com/yukunlabs/lunlet with a validation workflow, a preview-rejecting signed-candidate packager, a native-derived static product page, Sparkle 2.10.1 wired for configured release builds and a provenance inventory ([release preparation](releases.md)). No signed download, release, tag, hosted site, funding destination or paid service exists yet.
- Contributions arrive through feature branches and pull requests against `main`.

### Verified

- The default module suite, traceability and source-language checks, site tests, release-boundary tests and the opt-in panel/power cases pass; an isolated preview builds and passes strict signature verification. The Validate workflow runs on GitHub on pushes to `main` and pull requests, and accepts manual dispatch.

### Open gates

- Owner decisions: final artwork, branding and privacy-claim review; release and product-page destinations; Developer Program membership; the optional support destination and recipient. The 0BSD license, yukunlabs copyright identity and SPDX metadata are present, pending final publication review.
- An EdDSA update key, a published appcast and a real update between two versions on a clean Mac, with the first-open steps of an unsigned preview recorded and the saved bot connection confirmed intact afterwards; Developer ID signing and notarization deferred by owner decision; keyboard acceptance of the product page.

## Assisted acceptance checklist

End-to-end acceptance that needs the owner at the Mac, grouped here so no domain claims it by implication:

- With two existing sessions, including two in one project: initial locked notices, repeated follow-ups with retained context, approval isolation, stale, duplicate and expired actions, connection loss and recovery, exit and restore, and input revocation.
- On the Mac: focus preservation, notch and external-display placement, no cue while locked or asleep, no replay on return, display sleep, idle-sleep prevention and release, and that normal and OS-requested quit leave no owned child, socket or power assertion.
- A real account-limit read with verified source, freshness, unknown fields and overhead, and idle/active monitoring overhead measured on the device.
- The Feishu card in the phone app, including each in-place reply state.
