# Security policy

Lunlet runs on your Mac, stores messaging credentials in the macOS Keychain, and forwards a reply to a local Codex session only after its own checks. A flaw in any of those boundaries is a security issue.

## Report a vulnerability

Do not open a public Issue or pull request for a vulnerability. Use this repository's **Security → Report a vulnerability** form, which only the maintainer can read. Include the Lunlet version or commit, macOS version, the affected channel or agent, and the shortest reproduction with synthetic data. Never include real tokens, conversations or callback payloads.

The maintainer aims to acknowledge a report within seven days and to publish a fix, with credit if you wish, before any details become public.

## Supported versions

Lunlet is a source preview. Fixes land on the `main` branch; a signed release line will be stated here once releases exist.

## Out of scope

- Issues that require a modified Lunlet build, a modified Codex or Claude Code installation, or an already compromised Mac user account.
- The security of Feishu, Lark, Slack, Telegram, Codex or Claude Code themselves; report those to their vendors.
