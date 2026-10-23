# Lunlet

A quiet companion for your coding agents - on your desktop, within reach through Feishu.

Lunlet is a lightweight macOS companion for existing Codex CLI sessions. It shows activity, recent output, and account limits in a compact desktop panel. While you are away, Feishu delivers short summaries and lets you answer ordinary questions or send follow-up instructions to the same session.

Status: requirements and feasibility research. There is no runnable application yet.

Development is gated by confirmed user stories and acceptance criteria. Every code change must trace to them; see [story approval and traceability](docs/requirements.md#story-approval-and-traceability).

## First release

- Automatically monitor local Codex CLI sessions through a terminal-independent Codex integration.
- Briefly show task starts and completions in the desktop panel while the display is on.
- Connect a user-owned Feishu bot through the official scan-and-authorize flow.
- Enable Away Mode for all active sessions, keeping the Mac awake while allowing screen locking and display sleep.
- Continue existing work through Feishu cards; execution approvals stay on the Mac.

Linux is a later goal. New conversations from mobile, general computer control, tmux, SSH, and Desktop or IDE integrations are outside the first release.

Superset and iTerm are reference validation environments. Session support depends on compatible Codex interfaces, not a terminal-brand allowlist.

The selected stack is Swift, SwiftUI, and AppKit. Integration choices depend on feasibility results.

## Documentation

- [Requirements](docs/requirements.md): user stories, acceptance criteria, and release scope.
- [Feasibility](docs/feasibility.md): technical evidence and unresolved validation gates.
- [Contribution guidelines](AGENTS.md): repository conventions and engineering constraints.
