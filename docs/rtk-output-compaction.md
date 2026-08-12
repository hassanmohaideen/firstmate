# RTK output-compaction scout

The completed RTK source and benchmark scout identified v0.45.0 as the only candidate reviewed for a bounded Firstmate pilot. Executable integration is deferred in v1. Firstmate does not run RTK on project commands, expose `fm-brief.sh --rtk-compact`, or activate a home through `config/rtk`.

## Decision boundary

The reviewed macOS process interfaces do not provide this shell integration with a maintainable way to hash an opened regular-file descriptor and execute that same identity without reopening a mutable pathname. A private pathname, mode `0700` directory, repeated checksum, lock, or atomic rename does not close replacement by another process running as the same user. Firstmate therefore does not claim that those mechanisms admit exact pinned bytes.

[`bin/fm-rtk.sh`](../bin/fm-rtk.sh) is an operator-only static inspection command:

```sh
FM_HOME=/absolute/firstmate/home bin/fm-rtk.sh verify
```

It checks Darwin arm64 and opens the exact candidate path without following symlinks or blocking on a FIFO. It verifies an opened regular executable identity against SHA-256 `17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be`. It never executes RTK, invokes a project command, writes configuration, or treats verification as activation. The result only says that the bytes read during that inspection match the reviewed scout artifact.

The exact candidate path is `$FM_HOME/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk`. Placing anything there is a separate, explicit operator action. No tracked command installs, stages, downloads, discovers, updates, or removes the candidate.

## Denied surfaces

V1 has no compact Git log, diff, status, search, or listing command. It has no raw fallback because it accepts no project command. It does not alter projects, `PATH`, shell startup, prompts, hooks, plugins, filters, runtime adapters, bootstrap, session start, briefs, or secondmate charters.

RTK remains denied for lifecycle, state, axi, build, test, lint, formatting, migration, deployment, release, cloud, security, credential, mutation, validation, cleanliness, landing, approval, machine-readable, or authoritative output. Scout benchmark output remains non-authoritative and outside worker task execution.

## Privacy and failure model

Static inspection uses only fixed absolute system utilities and does not consult caller `PATH`. It passes no project command, search pattern, or project path to RTK because RTK never starts. It creates no temporary home, history, cache, data, analytics, or argument log. Invalid requests, unsupported platforms, unavailable inspection tools, and invalid artifact shapes fail without executing another command as a fallback.

## Updates and rollback

A future executable pilot requires a reviewed identity-bound launcher supported by authoritative Darwin interfaces, portable repository build conventions, and adversarial replacement, symlink, FIFO, signal, privacy, and no-rerun tests. It must also repeat review of the upstream tag and commit, release workflow, dependencies, license, provenance, telemetry, persistence, rewrites, filters, and open correctness or privacy issues.

Until then, rollback is deleting the manually placed candidate if the operator no longer needs scout verification. There is no config selection, generated task instruction, hook, prompt, shell edit, runtime integration, or project state to unwind.

## Ownership and audience

This document owns the maintainer architecture, denial, update, rollback, privacy, platform, and graduation criteria. [`docs/scripts.md`](scripts.md) inventories the operator command. `tests/fm-rtk.test.sh` owns executable coverage for request refusal, trusted utility resolution, exact platform and path, opened-identity hash, symlink, FIFO, executable mode, non-execution, and no project writes. Supported harnesses and backends are unaffected because none invokes this command automatically.
