# Messaging

Choose one channel in Settings → Messaging: Feishu/Lark, Slack or Telegram. Its connection entry appears at the lower left of the Codex panel. Switching channels stops the previous sender; credentials for the other channels remain saved.

Current scope: completion notifications while the Mac is confirmed locked. Each one shows, in the same order on every channel, the outcome and project, the agent and session, an excerpt of your latest request, the agent's final reply (cut only at the channel's message limit, ending "… The rest is on your Mac.") and the local time. On Feishu, a card for an open, idle Codex session also ends with a reply box: one reply, within ten minutes and while the Mac stays locked, continues that same session through its own `codex queue`. The box then greys out with your text and the same card shows the reply's progress: received, sent to Codex, and delivered once the session's record confirms it, or why it was not sent. Unlocking, expiry or a newer card for the session closes any open box in place. A separate receipt card appears only if Feishu refuses the update. On Telegram the notice ends with a Reply button that opens the reply box; on Slack you reply in the notice's thread. The same rules apply: one reply, within ten minutes and while the Mac stays locked, from your paired private chat; the notice is then rewritten in place with the reply's progress, and unlocking closes it. Claude Code notices take no replies. A scan-created Feishu app receives card replies on the long connection without console changes. Notifications are not replayed after an uncertain send, reconnect or unlock.

## Feishu / Lark

Open the connection entry and follow the official QR/web authorization flow. Choose your own eligible existing application or create one. Organization policies still apply.

## Slack

1. Open the connection card. Create Slack bot opens a prefilled official app manifest; Use existing app opens your app list. Review any configuration changes in Slack yourself.
2. Enable Socket Mode, subscribe to `message.im`, and enable the app's Messages tab. Install the app with bot scopes `chat:write`, `im:history` and `users:read`. The last scope verifies the bot's application identity; Lunlet does not enumerate people or conversations.
3. Create an app-level token with `connections:write`. Copy the Bot Token from OAuth & Permissions → Bot User OAuth Token and the App Token from Basic Information → App-Level Tokens. Enter them in Lunlet, then choose Connect.
4. Open the bot's private conversation and send the exact `lunlet <code>` message copied from Lunlet. The code expires after ten minutes. This is an ordinary private message, not a slash command.

Lunlet checks the bot, application and workspace before accepting a private recipient. Socket Mode is used during pairing and then closed. No public callback server is required. Use an app dedicated to Lunlet so another Socket Mode consumer does not compete for its events.

References: [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/), [app manifests](https://docs.slack.dev/app-manifests/configuring-apps-with-app-manifests/), [bot identity](https://docs.slack.dev/reference/methods/bots.info/), [private bot links](https://docs.slack.dev/interactivity/deep-linking/).

## Telegram

1. Create a bot with `/newbot` in BotFather, or use `/mybots` → choose your existing bot → API Token. Copy its token into Lunlet.
2. Choose Connect, then scan the QR code or open the Telegram link and tap Start in the bot's private chat.
3. Lunlet binds that private user/chat to the verified bot. The code expires after ten minutes; groups, forwarded messages and old messages cannot establish pairing.

Use a bot dedicated to Lunlet. An existing webhook is preserved and pairing stops with an explanation; Lunlet never removes it. Long polling runs only during pairing, preserves the existing update subscription and stops on success, cancellation, expiry or quit.

Reference: [Telegram Bot API](https://core.telegram.org/bots/api).

## Saved access and recovery

Tokens and paired recipients are stored on this Mac in `~/Library/Application Support/com.lunlet/credentials`, one file per service that only your user account can read; exported settings contain only the selected channel. Updates and rebuilds never ask for authorization. A connection that an earlier build saved in the Keychain is moved into the file on first use; if that build may not read it silently, Authorize access moves it once and the Keychain item is removed.

Check authorization validates the saved bot identity without sending a message. Global Refresh includes this check for the selected sender. Disconnect stops notifications and removes only that local saved connection; the provider application remains yours.

Synthetic API, socket, storage and lifecycle tests cover provider identity, private pairing, expiry, cancellation, receipt binding, channel switching and uncertain sends. Feishu, Telegram and Slack delivery and one reply per notice have been verified on the maintainer's devices; the Feishu card has not yet been reviewed in the phone app.
