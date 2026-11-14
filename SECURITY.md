# Security policy

Lunlet runs on your Mac. Four boundaries matter:

- Messaging credentials live in a file only your user account can read, sealed for this Mac and account, never in preferences, logs or exports.
- A reply from your phone reaches a local Codex or Claude Code session only after Lunlet's own checks of sender, session and turn; execution approvals stay on the Mac.
- While Claude Code is a selected agent, Lunlet adds a status line and a Stop hook to Claude Code's user settings and removes exactly those when Claude Code is turned off. It never reads Claude Code's sign-in credentials.
- A release build checks one update feed over HTTPS and installs an update only when it is signed for the project's update key.

A flaw in any of those boundaries is a security issue.

## Report a vulnerability

Do not open a public Issue or pull request for a vulnerability. Use this repository's **Security → Report a vulnerability** form, which only the maintainer can read. Include the Lunlet version or commit, macOS version, the affected channel or agent, and the shortest reproduction with synthetic data. Never include real tokens, conversations or callback payloads.

The maintainer aims to acknowledge a report within seven days and to publish a fix, with credit if you wish, before any details become public.

## Supported versions

The supported line is 0.2.x, published on GitHub Releases as unsigned previews (signed ad hoc, not notarized). Fixes land on the `main` branch and ship in the next release. A signed, notarized release line will be stated here once it exists.

## Out of scope

- Issues that require a modified Lunlet build, a modified Codex or Claude Code installation, or an already compromised Mac user account.
- The security of Feishu, Lark, Slack, Telegram, Codex or Claude Code themselves; report those to their vendors.
