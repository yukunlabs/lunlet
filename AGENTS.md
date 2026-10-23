# Lunlet contribution guidelines

- Read `README.md`, `docs/requirements.md`, and `docs/feasibility.md` before working. The requirements document is the source of truth for product scope and acceptance criteria.
- Use English for all repository-authored content: documentation, filenames, code identifiers, comments, UI copy, configuration descriptions, test fixtures, and future commit messages. Do not add Chinese text or bilingual copies.
- Express user-facing requirements as standard user stories: "As a [role], I want [goal], so that [benefit]." Give each story a stable ID and testable Given/When/Then acceptance criteria. Keep implementation choices and feasibility evidence separate.
- Keep the product lightweight: macOS first, Linux later; existing local Codex CLI sessions first; Feishu for short periods away from the computer. Validate session continuation before expanding the UI or adding agents.
- Integrate with Codex sessions independently of terminal products. Production discovery, observation, continuation, and eligibility must not depend on terminal-specific UI automation, terminal text parsing, or per-terminal control adapters. Superset and iTerm are reference test environments, not a capability allowlist. Keep optional destination navigation separate from session control.
- Use Swift, SwiftUI, and AppKit for the first release. Let verified differences drive abstractions; do not build a generic agent platform or a speculative cross-platform framework.
- Separate account-level limits from session-level state and usage. Label official values and estimates, and display unavailable values as unknown.
- Prefer event-driven observation and restrained quota refreshes. Measure background overhead during validation.
- Bind every remote action to the correct local installation, session, turn or request, and permitted Feishu identity. Check freshness and duplicates. Never inject input into whichever window happens to be focused.
- Keep execution approvals on the Mac. Mobile may answer ordinary questions or send follow-up instructions, but must preserve the session's existing sandbox and approval policy. Request names or prompt wording alone do not establish that a question is safe to answer remotely.
- Never commit tokens, cookies, credentials, personal conversations, user logs, or real callback payloads. Use sanitized fixtures and operating-system secure storage for secrets.
- Implement independently. Before reusing upstream code or assets, check the exact source version, license, attribution obligations, and dependencies. Do not choose a project license without user authorization.
- Keep documentation concise and evidence-based. Update existing documents instead of adding duplicate specifications, templates, or large tables of contents. Preserve stable story IDs when refining requirements.
- Resolve the gates in `docs/feasibility.md` before application implementation. Record reproducible evidence there; documentation and schema checks are not end-to-end tests.
- Use the `codex/` prefix for new branches. Publishing, remote pushes, and external resource creation require user authorization.

## Story-driven development

- No user story, no code. Follow [story approval and traceability](docs/requirements.md#story-approval-and-traceability). Before changing code, identify the `Confirmed` story and criterion IDs that authorize it; resolve applicable feasibility gates before application implementation.
- New stories and material behavior changes remain `Proposed` until product-owner confirmation is recorded. Never self-approve or silently change the confirmed baseline. Document missing, ambiguous, or conflicting requirements and stop affected implementation while continuing independent authorized work.
- Every implementation-plan task and code change must map story and criterion IDs to affected source, tests, and verification. Maintain `Implementation evidence` links under the affected stories. Tests must identify the criteria they verify; infrastructure and refactoring must explain which confirmed behavior they support.
- For code commits, include references in the body, for example `Refs: US-02, AC-02.01`. Documentation-only process changes do not need an invented product story.
- Block review for missing traceability, mismatched behavior, or unassessed requirement-change impacts. When code and CI are introduced, add automated checks for missing or invalid references and unconfirmed stories. Reference checks complement behavioral review; they do not prove acceptance.

## Commit conventions

Follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`. The scope is optional.

| Type | Purpose |
|---|---|
| `feat` | Add user-facing functionality |
| `fix` | Correct a bug |
| `refactor` | Restructure code without changing behavior |
| `docs` | Update documentation only |
| `test` | Add or update tests |
| `perf` | Improve performance |
| `style` | Change formatting without changing behavior |
| `build` | Change build tooling or dependencies |
| `ci` | Change continuous integration workflows |
| `chore` | Maintain repository configuration or tooling |
| `revert` | Revert an earlier commit; reference its hash in the body |

- Use lowercase types and scopes. Add a scope such as `codex`, `feishu`, or `panel` only when it helps identify the affected area.
- Write an imperative subject within 72 characters, including the prefix, without a final period. Describe the change itself.
- Keep each commit focused on one logical change. Add a body when rationale, tradeoffs, or migration steps need explanation.
- Mark breaking changes with `!` before the colon or a `BREAKING CHANGE:` footer, and explain the impact and migration steps.

Examples: `fix(feishu): reject expired card actions`, `docs: clarify away mode requirements`, `chore: initialize Lunlet`.
