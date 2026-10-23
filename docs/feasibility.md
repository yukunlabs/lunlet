# Feasibility

Last checked: 2026-10-25, using Codex CLI 0.163.0 and Apple Swift 6.4. These are inspected versions, not minimum supported versions.

Evidence comes from official documentation, CLI help, and a temporary app-server schema export. No live session continuation, account-limit query, Feishu registration, or complete mobile interaction has been verified.

## Evidence and remaining validation

| Area | Available evidence | Still to prove |
|---|---|---|
| Existing-session follow-up | Local `codex queue --help` and the [CLI reference](https://learn.chatgpt.com/docs/cli/reference#codex-queue) support targeting an existing session UUID | Continued context, original terminal synchronization, unchanged policies, receipts, and submission timeout behavior |
| Questions and approvals | User-input schemas include thread, turn, and item IDs. The [app-server reference](https://learn.chatgpt.com/docs/app-server#toolrequestuserinput) also routes some MCP authorizations through user-input requests | Answering the original pending CLI question and reliably excluding authorization requests based on provenance and purpose |
| Session lifecycle | The [thread lifecycle reference](https://learn.chatgpt.com/docs/app-server#unsubscribe-from-a-loaded-thread) describes retention after subscriptions and activity stop | Distinguishing live CLI sessions, idle turns, ended sessions, and loaded threads through Codex-level evidence; optional destination navigation is separate |
| Account limits | Local schemas and the [rate-limit reference](https://learn.chatgpt.com/docs/app-server#rate-limits-chatgpt) expose `account/rateLimits/read` with nullable fields | Actual supported fields, authentication, refresh behavior, and unknown or stale values |
| Feishu registration | The official [registration flow](https://github.com/larksuite/node-sdk#app-registration) supports scan-based creation, credential retrieval, and prefilled scopes, events, and `card.action.trigger`. `addons.preset: false` selects a minimal bot template | Automatic setup, verified owner identity, secure credential handling, and behavior under organization restrictions |
| Feishu callbacks | The [callback guide](https://open.feishu.cn/document/event-subscription-guide/callback-subscription/callback-overview) supports card interactions; the [persistent-connection guide](https://open.feishu.cn/document/ukTMukTMukTM/uYDNxYjL2QTM24iN0EjN/event-subscription-configure-) supports self-built applications | Swift integration or a justified SDK/CLI bridge, automatic transport configuration, and real card submissions and updates |

Feishu registration `addons` cannot set subscription transport or request URLs. Check the [application configuration API](https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/application-v7/application-v7/application-config/patch) before claiming fully automatic setup. A group webhook alone does not provide the required bidirectional channel.

## Validation order

Each experiment must cite confirmed story IDs and specific acceptance-criterion IDs from [the requirements](requirements.md). Record reproducible steps, sanitized source or test links, observed results, and supported versions; link the evidence from the affected stories. A documented API alone does not verify a criterion.

1. Prove terminal-independent identification and continuation of existing Codex CLI sessions. Compare [queue](https://learn.chatgpt.com/docs/cli/reference#codex-queue), [hooks](https://learn.chatgpt.com/docs/hooks), and [app-server](https://learn.chatgpt.com/docs/app-server) against the acceptance criteria. Superset and iTerm are reference clients, not separate control integrations.
2. Verify question provenance, approval isolation, concurrent sessions, stale and duplicate actions, timeouts, session exit, and restart recovery. Include enabling Away Mode with already-pending work, unavailable Feishu setup or connectivity, and permanent invalidation of old controls across mobile-access changes. Use dedicated test sessions and sanitized evidence.
3. Verify account-limit retrieval and useful summary extraction without an additional model service.
4. Verify scan-based Feishu setup and the complete mobile continuation and receipt flow while the Mac is locked and awake. Test display sleep, idle-sleep prevention, explicit sleep, network interruption, and cleanup separately.
5. Validate local start and completion cues, including presentation timeout, focus preservation, manually opened panels, concurrent events, duplicate suppression, display sleep and lock behavior, and displays without a notch. Local cues must work independently of Away Mode and Feishu connectivity.

Resolve these gates and review the integration approach before application implementation. Experiments must continue a session started on the Mac; a newly managed conversation cannot replace that requirement. Record versions, reproducible steps, outcomes, and failure boundaries here. Read-only checks do not satisfy runtime acceptance criteria.

Still undecided: minimum macOS version, final Codex integration, Feishu transport implementation, persistence dependencies, exact action-validity limits, and project license.
