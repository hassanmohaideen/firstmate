# Self-hosted Discord bot

This optional transport lets one running Firstmate home receive and answer the captain's Discord messages through a bot that runs on the same always-on computer.
It connects directly to Discord's Gateway and REST API.
It never calls myfirstmate.io, uses no Relay pairing token, and consumes no Relay message quota.
Relay remains a separate optional transport with its existing consent and behavior.

The transport is disabled until a private configuration is created and the service is started.
It currently accepts server messages only.
Direct messages and group direct messages are deliberately unsupported.

## Security boundary

One private configuration binds the bot to all three required authorization axes:

- One Discord owner user id.
- One allowed guild id.
- One allowed channel id.

The executable intake admits a message only when its direct author is that owner, its guild and channel exactly match the configured boundary, and it directly mentions this bot.
Bot-authored messages, webhook messages, other users, other guilds, other channels, unsupported message types, empty mentions, and messages without the direct bot mention are ignored before model context.
A thread is not implicitly included by its parent channel because a Discord thread has its own channel id.
Bind the explicit thread id instead when the bot should operate in one thread.

The direct owner message is a captain instruction within Firstmate's normal authority contract.
The public Discord channel still does not authorize destructive, irreversible, security-sensitive, credential, account, server-administration, or bot-configuration action.
Those actions require explicit confirmation in the trusted local session.
Project delivery rigor, merge authority, ask-user authority, and captain preferences are unchanged.

Replies are public-safe outcomes rather than worker or tool output.
The transport stores referenced-message text separately as untrusted surrounding context, never as direct-author instructions.
Raw Discord text stays in a private inbox and never enters an operational-input marker or durable notification row.
Outbound replies suppress all mention expansion, do not ping the replied-to user, stay below Discord's message limit, and revalidate the original guild/channel/message binding immediately before posting.

The bot token and configured owner, guild, and channel authorization ids live only in the local gitignored `config/discord-bot.env` file or an explicitly supplied process environment.
The interactive configurator writes a regular, single-linked mode-`0600` file and never accepts the token in command arguments.
The macOS LaunchAgent contains only local code and home paths.
It contains no token, owner id, guild id, or channel id.
Logs contain fixed safe lifecycle and diagnostic text rather than credentials, ids, message content, HTTP bodies, or Gateway payloads.

Treat the token like a password.
Do not paste it into chat, issues, commits, tests, shell arguments, service property lists, or diagnostic output.
If it is exposed, rotate it in the Discord Developer Portal and rerun the trusted local configuration step.

## Discord Developer Portal setup

Perform these account and server changes yourself in the [Discord Developer Portal](https://discord.com/developers/applications).
Firstmate does not create an application, generate or rotate a token, invite a bot, or change a Discord account or server.

1. Create an application and open its **Bot** page.
2. Create the bot user if the application does not already have one.
3. Under **Privileged Gateway Intents**, enable **Message Content Intent**.
4. Leave **Server Members Intent** and **Presence Intent** off because this transport does not request them.
5. Generate or reset the bot token only when you are ready to store it immediately through the private configurator.
6. Open **OAuth2** and use the URL generator for a guild install.
7. Select the `bot` scope.
8. Grant only **View Channels**, **Send Messages**, and **Read Message History** for an ordinary channel.
9. If the exact bound conversation will be a thread, also grant **Send Messages in Threads** and ensure the bot can view that thread; do not grant it for an ordinary channel.
10. Open the generated URL, choose the intended server, and approve the install yourself.
11. In Discord user settings, enable **Advanced -> Developer Mode**.
12. Use **Copy User ID** on the owner account, **Copy Server ID** on the allowed server, and **Copy Channel ID** on the exact allowed channel or thread.

Do not grant Administrator.
Do not grant message-management, role-management, member-management, webhook, mention-everyone, attachment, or voice permissions.
The bot needs no slash-command scope because activation is a direct mention in an ordinary allowed server conversation.

## Local configuration

Run the interactive configurator from the Firstmate code root in the trusted local terminal:

```sh
bin/fm-discord-bot.sh configure
```

It prompts for the token with terminal echo disabled, then prompts for the owner user id, allowed guild id, and allowed channel id.
It validates the complete configuration before atomically replacing any existing file.
Unsafe file types, links, modes, duplicate keys, unknown keys, missing values, malformed ids, control characters, and surprising token lengths are refused with an actionable diagnostic.

The resulting private file has exactly these keys:

```text
FM_DISCORD_BOT_TOKEN=<secret bot token>
FM_DISCORD_OWNER_USER_ID=<owner user id>
FM_DISCORD_GUILD_ID=<allowed guild id>
FM_DISCORD_CHANNEL_ID=<allowed channel or thread id>
```

The placeholders above are documentation only.
Never commit real values.

For a foreground process managed by another service system, all four names may instead be supplied in that process environment.
The macOS service path intentionally reads the private file so the token is never copied into its property list.

## Start, check, and stop on macOS

Start the persistent per-home LaunchAgent with:

```sh
bin/fm-discord-bot.sh start
```

The command validates Node.js and configuration first, writes a home-derived LaunchAgent under `~/Library/LaunchAgents/`, loads it in the current Aqua login domain, and starts it.
The service uses `RunAtLoad`, restart-on-failure `KeepAlive`, and a 15-second launchd throttle, so it survives process crashes and starts again after machine restart and user login.
The process reconnects ordinary Discord disconnects itself and resumes the existing session whenever Discord permits it.
Reconnect pressure and the last connection attempt survive process and service-manager restarts, as well as READY and RESUMED events, until the connection remains healthy for five minutes or has at least three acknowledged heartbeats spanning two minutes.
Unstable connections use randomized exponential delays with a five-second minimum connection interval, a five-minute local delay cap, and a separately jittered cooldown capped at 15 minutes after eight consecutive unstable outcomes; a longer Discord `retry_after` remains the minimum wait.
Discord-directed reconnect and invalid-session responses retain or clear session material as required and still pass through the same pacing policy.
Fresh Identify attempts reserve Discord's authenticated `session_start_limit` durably and wait through an exhausted reset window, while a valid Resume remains available without consuming a new session start.
It also holds a recoverable per-home process lock so a manual start and LaunchAgent cannot create two Gateway sessions.
The shell admits and hands the lease to the Node runtime before Gateway I/O; the runtime remains its canonical owner for its full lifetime, including after wrapper loss, and direct Node invocation cannot bypass ownership.

Check configuration and current service health with:

```sh
bin/fm-discord-bot.sh check
```

The check reports one of the disabled, invalid, stopped, terminally stopped, connecting, reconnecting, or connected outcomes without printing credentials or deployment ids.
Authentication rejection, missing Message Content intent, invalid Gateway intents, invalid Gateway version, sharding configuration, or authenticated Gateway metadata, unavailable Discord API, Gateway connection failure, untrusted reconnect state, reconnect-state persistence failure, and private inbox publication failure use bounded safe diagnostic codes.
Authentication rejection and other non-retryable Gateway configuration close codes stop all Gateway reconnects and persist that suppression across service-manager restarts.
Only a changed bot authentication identity or explicit operator intervention through `bin/fm-discord-bot.sh retry` or `bin/fm-discord-bot.sh configure` clears terminal suppression; owner, guild, and channel filtering changes do not clear it.
A new service diagnostic reaches the active Firstmate through the existing durable notification queue exactly once until the code changes or stable recovery clears it.

Stop the service and prevent the LaunchAgent from returning at the next login with:

```sh
bin/fm-discord-bot.sh stop
```

Stop removes the per-home LaunchAgent and live service markers but leaves the private configuration, pending inbox, and durable conversation bindings unchanged.
An unanswered inbox continues to count as supervision need until Firstmate answers it.

After correcting a terminal application setting that does not change the private configuration, explicitly clear reconnect suppression with:

```sh
bin/fm-discord-bot.sh retry
```

This command does not start the service.
It allows only the next operator or service-manager start, and another terminal rejection suppresses reconnects again.
Rerunning the interactive configurator also clears terminal suppression after it safely replaces and revalidates the private configuration.

For foreground operation under an operator-owned service manager, use:

```sh
bin/fm-discord-bot.sh run
```

Persistent automatic startup outside macOS is not currently supplied by Firstmate.

## Use

In the configured server channel, directly mention the bot and include a non-empty message.
For example, ask it for current work or give it a normal reversible project request.
The bot ignores a message that merely appears near the bot without a direct mention.

An accepted message is privately committed before a structural `discord-message` notification enters Firstmate's existing durable queue.
The active primary harness receives that notification through its normal supervision protocol.
Firstmate applies the conditional `discord-respond` procedure, sends the immediate answer directly to the bound Discord message, and records a narrow task binding when longer work in this home owes one terminal outcome.
Automatic terminal returns are not yet carried across a secondmate-home route; Firstmate must avoid promising that public final and keep the ordinary trusted local outcome when a request routes elsewhere.
A bounded, idempotent REST retry uses the same Discord nonce, and a private per-phase sent receipt prevents a local cleanup retry from intentionally creating a duplicate answer.

Private request context is pruned after seven days once the pending inbox is gone and no task still carries its terminal-return binding.
Discord-owned durable wake deduplication receipts are retained for at least eight days: the full seven-day context horizon plus one day of crash and reconciliation overlap.
Accepted and pending receipts remain beyond that window while their pending inbox, conversation context, or current diagnostic can still be retried; stale pending receipts are removed only after that source is absent.
Pruning ignores other queue producers' receipts and preserves unsafe artifacts for operator inspection.
Pending inbox records and context still owed by linked work are not pruned merely because they are old.
A successful reply removes the pending inbox only after Discord accepts the post, while the context remains available for an owed terminal reply.

## Troubleshooting

Run `bin/fm-discord-bot.sh check` first.
Then inspect `state/discord-bot.log` only for the safe lifecycle or diagnostic code it names.
The log should never contain a token, id, or message body.
A `context pruning was skipped` line concerns private local cleanup and does not diagnose Gateway authentication or connection health; use the `check` outcome for that.

An `authentication-rejected` diagnostic means the stored token is invalid or revoked.
Rotate the token in the trusted Developer Portal session, rerun `configure`, and start the service again.
The unchanged rejected configuration remains suppressed even if a service manager tries to relaunch it.

A `message-content-intent-disabled` diagnostic means **Message Content Intent** is off for the application.
Enable that one privileged intent, run `bin/fm-discord-bot.sh retry` to record the operator intervention, and start the service again.
Invalid intent, Gateway version, or sharding diagnostics are also terminal configuration failures and require correcting the application or runtime configuration before retrying.
A `gateway-configuration-invalid` diagnostic means Discord returned Gateway metadata the runtime could not safely use; confirm the current Firstmate version and Discord service status before running `retry` and starting once more.

A `reconnect-state-invalid`, `terminal-suppression-invalid`, or `reconnect-state-unavailable` diagnostic means the private reconnect records could not be trusted or updated safely.
Stop the service, correct any local storage, file-type, or mode problem in the [documented private state boundary](configuration.md#self-hosted-discord-configdiscord-botenv), run `retry`, and then start the service again.

A connected service that ignores a message is usually enforcing the owner, guild, channel, author-type, or direct-mention boundary.
Confirm those ids locally with Developer Mode and rerun `configure` rather than weakening the checks.

A reply rejected for channel permission needs the bot's **View Channels**, **Send Messages**, or **Read Message History** permission in that exact channel.
A bound thread additionally needs **Send Messages in Threads** and bot access to that thread.
Do not solve either case by granting Administrator.

The implementation and safety ownership boundary is in [`architecture.md`](architecture.md#optional-self-hosted-discord).
The local configuration schema is owned by [`configuration.md`](configuration.md#self-hosted-discord-configdiscord-botenv).
Repeatable maintainer evidence is recorded in [`verification/discord-bot.md`](verification/discord-bot.md).
