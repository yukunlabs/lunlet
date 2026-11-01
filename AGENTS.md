# Lunlet working instructions

This file holds the working instructions for AI coding agents and maintainers of this repository; contributors should start with [CONTRIBUTING.md](CONTRIBUTING.md).

- Read `README.md`, `docs/requirements.md`, and `docs/feasibility.md` before working. The requirements document is the source of truth for product scope and acceptance criteria.
- Use English for all repository-authored content: documentation, filenames, code identifiers, comments, UI copy, configuration descriptions, test fixtures, and future commit messages. Do not add Chinese text or bilingual copies.
- Group requirements into user-outcome Epics, with exactly one primary Epic per story and explicit dependencies across Epics. Keep product approval, release membership, implementation evidence and runtime acceptance distinct. Express user-facing requirements as standard user stories: "As a [role], I want [goal], so that [benefit]." Give each story a stable ID and testable Given/When/Then acceptance criteria. Keep implementation choices and feasibility evidence separate.
- Keep the product lightweight: macOS first, Linux later; local Codex and Claude Code observation across supported clients, with original-CLI continuation separately gated; one user-owned Feishu/Lark, Slack or Telegram channel for short periods away from the computer, with Feishu card input as the first continuation target. Validate session continuation before expanding the UI or adding agents.
- Integrate with Codex sessions independently of terminal products. Production discovery, observation, continuation, and eligibility must not depend on terminal-specific UI automation, terminal text parsing, or per-terminal control adapters. Superset and iTerm are reference test environments, not a capability allowlist. Keep optional destination navigation separate from session control.
- Use Swift, SwiftUI, and AppKit for the first release. Let verified differences drive abstractions; do not build a generic agent platform or a speculative cross-platform framework.
- Separate account-level limits from session-level state and usage. Label official values and estimates, and display unavailable values as unknown.
- Prefer event-driven observation and restrained quota refreshes. Measure background overhead during validation.
- Bind every remote action to the correct local installation, session, turn or request, and permitted Feishu identity. Check freshness and duplicates. Never inject input into whichever window happens to be focused.
- Keep execution approvals on the Mac. Mobile may answer ordinary questions or send follow-up instructions, but must preserve the session's existing sandbox and approval policy. Request names or prompt wording alone do not establish that a question is safe to answer remotely.
- Never commit tokens, cookies, credentials, personal conversations, user logs, or real callback payloads. Use sanitized fixtures and operating-system secure storage for secrets. Normal Lunlet access to its own saved Feishu enrollment is part of the authorized application flow; do not run independent credential-reading probes without explicit owner authorization.
- Implement independently. Before reusing upstream code or assets, check the exact source version, license, attribution obligations, and dependencies. Do not choose a project license without user authorization.
- Keep documentation concise and evidence-based. Update existing documents instead of adding duplicate specifications, templates, or large tables of contents. Preserve stable story IDs when refining requirements.
- Record new owner feedback as TODOs by default. Bugs have priority 1; new features have priority 2. Do not start diagnosis or implementation until the owner asks to work on them. Follow the feedback intake and priority rules in `docs/requirements.md`.
- Resolve the applicable gates in `docs/feasibility.md` before enabling a live integration capability. Independently testable core work may proceed while an integration remains unavailable. Record reproducible evidence there; documentation, schema checks, and offline tests are not end-to-end acceptance.
- Work on short-lived feature branches and open pull requests against `main`; the maintainer merges after review. Publishing, remote pushes outside a pull request, and external resource creation require the owner's authorization.

## Story-driven development

- No user story, no code. Follow [story approval and traceability](docs/requirements.md#story-approval-and-traceability). Before changing code, identify the `Confirmed` story and criterion IDs that authorize it; resolve applicable feasibility gates before application implementation.
- New stories and material behavior changes remain `Proposed` until product-owner confirmation is recorded. Never self-approve or silently change the confirmed baseline. Document missing, ambiguous, or conflicting requirements and stop affected implementation while continuing independent authorized work.
- Every implementation-plan task and code change must map story and criterion IDs to affected source, tests, and verification. Maintain `Implementation evidence` links under the affected stories. Tests must identify the criteria they verify; infrastructure and refactoring must explain which confirmed behavior they support.
- Ship the product page with the product. A story the page presents declares `Product page: #section` in `docs/requirements.md`; the site build fails when a section presents an unconfirmed story or a confirmed story's section does not present it, when the page's per-agent, per-messenger or per-skin blocks do not match the sources, or when the stills' manifest no longer matches the sources. After changing anything under `Sources/` or the render scenery, run `scripts/render-site-assets.sh` and commit the result; `python3 scripts/check_site_assets.py` is the check.
- Maintain story and acceptance-criterion references in source headers, tests, and requirement evidence. Keep commit messages focused on the change and its rationale; omit duplicate reference lists.
- Block review for missing traceability, mismatched behavior, or unassessed requirement-change impacts. When code and CI are introduced, add automated checks for missing or invalid references and unconfirmed stories. Reference checks complement behavioral review; they do not prove acceptance.

Use `com.lunlet` for the application, signing, and unified-log identifiers. Use `com.lunlet.feishu` for new enrollment storage; retain older identifiers only where required for credential compatibility.

## Path naming

- Follow toolchain and language conventions rather than applying one casing rule to every path. Preserve `Package.swift`, `Sources/`, `Tests/`, `Resources/`, `Info.plist`, `README.md`, and `AGENTS.md`.
- Use `UpperCamelCase` for Swift target directories and Swift source/test filenames, naming files for their main type or cohesive group of types. Preserve Swift's `main.swift` entry-point spelling.
- Use lowercase names with hyphens for supporting directories, Markdown documents, and shell scripts, such as `docs/requirements.md` and `scripts/test-core.sh`.
- Use `snake_case.py` for Python files, including executable test fixtures. Keep naming consistent within each category and update references when renaming a path.
- Generated files retain their generator's filenames and headers. Regenerate them from their traceable source declarations instead of editing them by hand.

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

- Use lowercase types and scopes. Add a scope such as `codex`, `claude`, `feishu`, or `panel` only when it helps identify the affected area.
- Write an imperative subject within 72 characters, including the prefix, without a final period. Describe the change itself.
- Keep each commit focused on one logical change. Add a body when rationale, tradeoffs, or migration steps need explanation.
- Mark breaking changes with `!` before the colon or a `BREAKING CHANGE:` footer, and explain the impact and migration steps.

Examples: `fix(feishu): reject expired card actions`, `docs: clarify away mode requirements`, `chore: initialize Lunlet`.


## Verification efficiency

- Identify root causes and affected behavior before each fix; add focused regression coverage for relevant real-world boundaries, such as shared projects, similar session IDs, changing connections and uncertain states.
- Unit tests, synthetic fixtures and traceability checks do not replace real interaction acceptance. For native UI, window targeting, authorization or cross-app navigation, verify the corresponding interaction in the packaged app; otherwise report the acceptance gap and never claim end-to-end success.
- When the hosted Validate run fails, sweep the whole repository for that class of failure before pushing again (slow type-checking expressions with `-warn-long-expression-type-checking`, timing assumptions in tests); fixing only the reported site costs one CI round per occurrence.
- Distinguish checks that passed, failed or were not run, and review adjacent core flows at the change boundary. Retain incremental builds and focused tests; repeated tests and full rebuilds are not substitutes for meaningful acceptance.
- Keep tests focused on distinct behavior and failure boundaries. Consolidate duplicate fixtures/assertions; do not delete authorization, cancellation, binding, or cleanup coverage merely to reduce test counts.
- During edits, use `scripts/test-core.sh core|codex|claude|feishu|messaging|storage|desktop` or a focused `--filter`. Run dependent desktop regressions after Codex/Claude/Feishu changes and the full default suite at a completed change boundary. Native panel, diagnostics, and power tests remain explicitly enabled checks for relevant changes, rather than defaults on every edit.
- Share Swift compiler flags between builds/tests through `scripts/swift-common.sh`. Keep the incremental cache; do not clean it or skip builds after source changes to make checks appear faster. Repackage the application when preparing on-device evaluation.
- Normal application packages require stable certificate signing. Build previews with a locally trusted development certificate, for example `LUNLET_CODE_SIGN_IDENTITY="Lunlet Development" scripts/build-app.sh --preview`; without the variable a preview is signed ad hoc. Either way the Keychain identifies a preview by its binary, so a build with changed code needs the owner to click Authorize access once, after which relaunches of that binary are silent (the store re-creates the item under the running build). By the owner's decision of 2026-11-01 the first downloadable release is an unsigned preview (`LUNLET_CODE_SIGN_IDENTITY=- LUNLET_RELEASE_UNSIGNED=1`), whose notes say that macOS asks to allow it on first open and that each update asks once to authorize the saved bot connection; credential continuity across signed updates is verified with the Developer ID certificate if and when the owner signs. Never ask the owner to remove the connection or scan again to recover access. A same-process synthetic storage test is not evidence of credential continuity across signed application updates.
