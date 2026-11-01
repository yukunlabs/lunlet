# Contributing to Lunlet

Lunlet is a macOS companion for existing local Codex and Claude Code work. The public source preview and its limitations are described in [README](README.md). Before proposing a change, read the [product requirements](docs/requirements.md), [feasibility evidence](docs/feasibility.md), and [repository conventions](AGENTS.md). Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1).

## Start with the user outcome

Use the Bug report or Feature request Issue form. A bug report should identify the affected app and version, the expected and observed behavior, and the shortest safe reproduction. A feature request should describe who benefits and what outcome would show success. Search existing Issues first. Do not post tokens, account details, conversation text, unredacted screenshots, logs, or real provider payloads.

A submitted Issue does not start implementation or change the confirmed product scope.

New product behavior needs an owner-confirmed user story and Given/When/Then criteria in `docs/requirements.md` before application code changes. An Issue or PR alone does not confirm a story. Keep proposed behavior distinct from confirmed release scope and implementation evidence. Small corrections to existing confirmed behavior should cite the story and criterion they restore.

## How work is planned

Work iterates by feature module: core, codex, claude, feishu, messaging, storage and desktop, the scopes of `scripts/test-core.sh`. Issues are the intake; the maintainer records new feedback before scheduling it, with bugs at priority 1 and new features at priority 2. A story is confirmed in `docs/requirements.md` before its implementation starts. Releases are tagged from `main` as [release preparation](docs/releases.md) describes.

## Make a focused pull request

Fork the repository or create a short-lived branch from `main`, and keep one logical change per pull request with unrelated changes left out. Write the subject as a Conventional Commit, `type(scope): description`, as [AGENTS.md](AGENTS.md#commit-conventions) describes. Link the Issue and the story/criterion IDs, and fill in the pull request template. Follow the repository's English-only content and path conventions in `AGENTS.md`. Preserve provider identity, authorization, cancellation and cleanup boundaries. Never include real secrets or personal session data; use synthetic fixtures. Check upstream licenses and attribution before adding dependencies or assets.

Run the relevant module first (`scripts/test-core.sh core|codex|claude|feishu|messaging|storage|desktop`) and the full default suite at the change boundary. Run `python3 scripts/test_traceability.py`, `python3 scripts/check_traceability.py`, and `git diff --check`. For website changes, run `python3 scripts/test_site.py` and build the site locally. After a change under `Sources/` or to the render scenery, run `scripts/render-site-assets.sh` so the page's stills match the interface; `python3 scripts/check_site_assets.py` reports whether they do. If native interaction, live messaging or a signed update matters, describe what was actually tested and what remains unaccepted. Synthetic tests do not establish live delivery.

The hosted `macos-26` runner differs from a development Mac: its Swift toolchain lags the current Xcode release and it is slower under load. Before pushing, build with `-Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=100` and split any expression it reports, keep test waits on ten-second deadlines with one deadline per wait, and do not assert absolute wall-clock times below half a second.

The maintainer reviews external PRs for product scope, correctness, privacy, licensing and evidence. Address review conversations before merge. The default branch is protected: merging requires the Validate check and resolved conversations, and direct pushes, force pushes and deletion are disabled. An independent approval requirement is added when a second maintainer is available.

## Report security issues privately

Do not open a public Issue for a vulnerability or include exploit details in a PR. Private vulnerability reporting is enabled: use the repository's **Security → Report a vulnerability** flow as [SECURITY.md](SECURITY.md) describes.
