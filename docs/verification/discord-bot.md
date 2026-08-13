# Self-hosted Discord verification

Audience: maintainer verification.

This record supports the active guarantees for Firstmate's optional direct self-hosted Discord transport.
[`../discord-bot.md`](../discord-bot.md) owns current operator and security behavior.
[`../configuration.md`](../configuration.md#self-hosted-discord-configdiscord-botenv) owns configuration and local runtime state.
[`../architecture.md`](../architecture.md#optional-self-hosted-discord) owns mechanism boundaries.

## Hermetic protocol and safety pass

The executable transport suite ran on 2026-08-13 with Node.js v25.9.0, jq 1.7.1, and macOS Bash 3.2 compatibility syntax.
It used generated fake tokens and ids inside private temporary homes.
It made no live Discord, myfirstmate.io, Relay, GitHub, browser, account, bot, server, or channel change.

Command:

```sh
bin/fm-test-run.sh tests/fm-discord-bot.test.sh
```

Observed bounded output:

```text
ok - self-hosted Discord is inert without explicit private configuration
ok - Discord configuration rejects unsafe ambiguity without exposing secrets or ids
ok - eligible owner mentions publish one private inbox and one durable notification
ok - Discord notification acceptance remains idempotent across process death
ok - Discord wake receipts retain sources and safely prune accepted and pending artifacts
ok - Discord intake enforces owner, guild, channel, direct mention, and bot-loop prevention
ok - outbound replies authenticate directly, suppress mentions, and preserve the bound conversation
ok - terminal Discord replies survive bounded REST retries and clear their exact task binding
ok - the Gateway reconnects, remains single-instance, and shuts down cleanly
ok - foreground service accepts Discord's regional resume endpoint independently of private-state pruning
ok - Gateway resume remains limited to Discord-owned endpoints
ok - reconnect policy retains READY failure pressure, resets only after stability, and applies bounded jitter
ok - rapid Gateway disconnects remain bounded and stop promptly during cooldown
ok - server reconnect and invalid-session directions choose resume or fresh identify correctly
ok - Gateway lookup rate limits preserve server-provided retry direction
ok - READY retains failure pressure until sustained stable Gateway operation
ok - terminal authentication failure stops reconnects across service-manager restarts with one safe diagnostic
ok - terminal Gateway close performs no reconnect
ok - diagnostic persistence failures preserve terminal reconnect suppression
ok - the macOS service path reaches connected without copying credentials or deployment ids
ok - reply helpers resolve only strict shared custom configuration records
ok - self-hosted Discord and Relay coexist while sharing only durable supervision
```

The fake REST endpoint records only an authentication-match boolean and parsed request body, never the fake token.
The fake Gateway performs a real local WebSocket upgrade, sends Discord v10 Hello, waits for an authenticated Identify carrying the minimum intent bitset `33281`, sends Ready, closes the first connection, and observes a valid Resume on the second connection.
A separate READY fixture returns a Discord-owned regional resume hostname and reaches `connected` through both the foreground shell entrypoint and the real Node child launched behind the fake macOS service boundary.
The same lifecycle rejects a lookalike hostname outside Discord's domain.
The production runtime's alternate API and Gateway inputs have no effect unless its hermetic test-mode flag is set.
Production destinations remain fixed to Discord's authenticated API and canonical or regional Discord-owned Gateway hosts.

The authorization matrix drives the same executable `ingestMessage` owner used by Gateway `MESSAGE_CREATE` events.
It positively admits one owner-authored, exact-guild, exact-channel, direct-bot-mention message and negatively drives wrong owner, wrong guild, wrong channel, missing mention, and bot-authored inputs.
The accepted path asserts a mode-`0700` private inbox directory, mode-`0600` inbox and context files, mention-stripped direct text, separately retained untrusted parent context, one structural wake row, durable offer deduplication, and no inbox recreation after answer.

The outbound pass drives the same REST code as `fm-discord-reply.sh` and asserts the exact channel endpoint, guild/channel/message reference, direct bot authentication, disabled outbound mention parsing, `replied_user=false`, enforced stable nonce, private phase-sent receipt, post-success inbox removal, and retained durable context.
The terminal pass first proves ordinary task cleanup refuses while the Discord outcome is owed, then returns HTTP 500 once and success, proving one bounded retry with the same final-scope nonce before only the exact task binding clears.

The fake-time policy pass drives fixed random samples and unstable durations through the executable test seam.
It bounds an hour of rapid successful handshakes to at most 12 connections, proves READY alone does not reset pressure, proves a stable interval does reset pressure, and checks the jitter endpoints remain within the configured cap.
The real local Gateway storm pass repeatedly sends READY or RESUMED and disconnects, then asserts the connection count remains bounded and TERM interrupts the active cooldown promptly.
The directed reconnect pass proves Opcode 7 and resumable Opcode 9 retain the session, while non-resumable Opcode 9 clears it before the next Identify.
The local HTTP 429 pass proves the authenticated Gateway lookup honors Discord's bounded retry direction instead of using only client backoff.
The stable-recovery pass creates a transient HTTP failure, reaches READY with its diagnostic still present, and observes that diagnostic clear only after the configured sustained-health interval.
The authentication-failure pass returns HTTP 401 once, publishes one `authentication-rejected` notification, persists terminal suppression, and proves a second service-manager invocation makes no HTTP or Gateway request.
The terminal close pass sends Gateway close code 4004 before READY and observes one connection with no retry.
The fixed output, health output, private service record, and property-list assertions reject the generated token and authorization ids.
The worker pass starts the real shell single-instance wrapper, proves a second start is refused, sends TERM, and verifies enabled and ready markers retire.
The regional READY pass also leaves the pruning-warning precondition active and still reaches connected, proving that cleanup warning is not the handshake cause.

The LaunchAgent pass uses a private `HOME` and fake `launchctl` while driving the real `start`, worker, Node runtime, health check, and `stop` entrypoints against the fake Gateway.
It asserts the persistent path reaches connected, plus `RunAtLoad`, restart-on-failure `KeepAlive`, restart throttling, per-home naming, and complete absence of token, owner id, guild id, and channel id from the property list.
This is executable contract evidence, not a claim that a real Aqua login launchd service or live Discord bot was changed during development.
The operator-run real-account smoke remains `bin/fm-discord-bot.sh start`, `check`, one owner mention in the bound channel, and `stop` after the captain performs the documented Developer Portal setup.

## Primary harness applicability review

The review covered every primary harness currently supported by the README and configuration owner.
The Discord runtime never calls a harness executable or injects raw Discord text into a harness composer.
It commits private input, calls the queue's idempotent append path through `fm-discord-notify.sh`, and lets the existing structural `check` path wake the active primary.

| Primary harness | Applicability | Maintained reason |
| --- | --- | --- |
| Claude | Applicable through the shared predicate and Stop-owned auto-arm | `fm-claude-stop-autoarm.sh` calls `fm_supervision_needed`, which now includes the direct service or pending inbox, while the ordinary watcher delivers the structural check |
| Codex | Applicable through foreground watcher checkpoints | The checkpoint runs the same watcher and queue, with no Discord-specific foreground or background process inside Codex |
| Grok | Applicable through the tracked background watcher | The Grok protocol now re-arms while shared supervision remains needed rather than naming only work or Relay |
| OpenCode | Applicable through the primary TUI watcher plugin | The plugin owns the same watcher child and receives the same structural check close |
| Pi | Applicable through the primary watcher extension | The extension owns the same watcher arm and successor path, while the Discord service remains an independent LaunchAgent process |
| pi-signed | Applicable through Pi's shared primary protocol | The renderer preserves the signed identity and reuses the same Pi watcher extension path |

Kimi remains outside the supported primary turn-end integrations, and Muse remains worker-only, so neither is promoted by this feature.
The unknown-harness fallback remains unknown and receives no new compatibility claim.
No harness-rendered string, process title, key binding, or vendor payload is introduced by this transport, so the live harness-dependent check policy does not require a new vendor-version smoke.
The maintainable portable proof is the shared supervision predicate and structural queue event exercised by `tests/fm-discord-bot.test.sh`; existing live primary supervision evidence remains in [`supervision.md`](supervision.md).

## Runtime backend applicability review

The review covered every spawn-capable runtime backend: tmux, Herdr, Zellij, Orca, and cmux.
The direct Discord process does not create, capture, send to, inspect, or close a task endpoint.
It calls no operation in `bin/fm-backend.sh` or `bin/backends/`.
All five backends are therefore not applicable to transport mechanics, while tasks started from a Discord request continue through their already selected backend and normal lifecycle.
The v1 terminal-return metadata binding is deliberately home-local and makes no cross-secondmate claim.

The away-mode path is also unchanged.
The existing daemon classifies every `check:` event as an escalation, so a direct Discord message uses the same backend-independent queue input and the daemon's already supported supervisor delivery path.
That fact does not expand the daemon's current tmux/Herdr supervisor-pane support to Zellij, Orca, or cmux.

Codex App remains not selectable as a runtime backend and receives no new claim.
The active runtime evidence remains in [`runtime-backends.md`](runtime-backends.md), while this record is the owner of the not-applicable review for the Discord transport.

## Relay coexistence

The direct transport has separate configuration keys, state directories, service process, request ids, task metadata fields, reply executable, and Discord API connection.
It does not source Relay consent, call a Relay URL, or create/remove `state/x-watch.check.sh` or `config/x-mode.env`.
The only shared mechanism is the existing durable queue and supervision-need predicate.

The coexistence case creates both a Relay poll shim and a direct Discord service marker, then asserts both are represented by the shared predicate and the Relay artifact remains untouched.
It next stops the direct service, leaves a pending direct inbox, and proves supervision remains needed for that unanswered message.
The broader Relay behavior remains covered by:

```sh
bin/fm-test-run.sh tests/fm-x-mode.test.sh
```

## Refresh commands

The same pass also includes a narrow Bash 3.2 source guard in `bin/fm-backend.sh` so teardown can refuse a missing Herdr adapter instead of exiting its prerequisite function early under `set -e`; the existing full teardown suite pins that unrelated safety regression.

After changing the transport, configuration parser, durable notification, supervision predicate, or reply binding, rerun:

```sh
bin/fm-test-run.sh tests/fm-discord-bot.test.sh
bin/fm-test-run.sh tests/fm-operational-input.test.sh tests/fm-wake-queue.test.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh
bin/fm-test-run.sh tests/fm-x-mode.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

The first test is the feature owner.
The remaining commands protect the reused operational-input, queue, supervision, Relay coexistence, documentation, and shell surfaces without a live credential.
