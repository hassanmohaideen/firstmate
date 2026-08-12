# Optional RTK output compaction

Firstmate's RTK pilot is a disabled-by-default optimization for supplemental task orientation.
It is not a command interception layer, a validation tool, or a source of authoritative evidence.
[`docs/configuration.md`](configuration.md#optional-rtk-output-compaction-configrtk) owns the home-local selection and private artifact layout.
[`bin/fm-rtk.sh`](../bin/fm-rtk.sh) and its `--help` output own the exact verbs, argv mappings, pin checks, environment, fallback mechanics, and exit behavior.

## Architecture boundary

An ordinary ship or scout receives the helper instruction only when its brief is scaffolded with `fm-brief.sh --rtk-compact`.
Persistent secondmate charters refuse the flag because this pilot has no evidence for changing a whole persistent domain's operating behavior.
The generated instruction binds the exact Firstmate home and helper path instead of adding RTK to `PATH`.
No worker runtime adapter, backend, shell startup file, global prompt, project instruction file, hook, plugin, or project filter is changed.

The helper exposes semantic verbs instead of accepting a command string.
The supported classes are bounded Git history, unstaged or staged Git diff orientation, plain Git status orientation, unstructured `rg` search, and one-directory listing.
Arguments remain argv data and are never evaluated by a shell.
Search and list targets are resolved against the current physical task-copy root and refused when they leave it, traverse symlinks or parent components, enter credential/private metadata directories, or do not already exist.
Git invocations use fixed command-scoped configuration with external diff, text conversion, fsmonitor, hooks, pagers, protocols, and optional index locks disabled.
Option passthrough, standalone shell operators, and arbitrary command execution are refused before either RTK or the raw program starts.

Compact output is never sufficient for a safety, mutation, validation, final-review, cleanliness, landing, or approval decision.
The worker must run the corresponding raw command before making one of those decisions.
That second raw invocation is explicit and visible rather than an automatic retry hidden inside the helper.

## Denied surfaces

The pilot never applies to Firstmate lifecycle or supervision, state, metadata, backlog, configuration, checks, migrations, deployment, or release evidence.
It never applies to `tasks-axi`, `quota-axi`, `no-mistakes axi`, `gh-axi`, another structured axi tool, or output consumed by a parser.
It never applies to JSON, XML, CSV, NUL-delimited, porcelain, checksum, signature, patch, or other machine-readable output.
It never applies to exact file reads, builds, tests, lint, formatting, package management, code generation, migrations, deployments, cloud operations, security checks, credential or secret access, mutations, or approval commands.
It provides no RTK proxy, direct RTK command, generic `--` escape hatch, pipeline, redirection, command substitution, or compound shell command.

These denials are intentionally broader than the current RTK rewrite registry.
A future upstream release can add a rewrite or alter a filter without changing Firstmate, while Firstmate's structured and lifecycle contracts require exact evidence.
A positive result from an exploratory compact view therefore never widens the allowlist by analogy.

## Privacy and failure model

The helper verifies the selected artifact before each compact use and never runs an artifact that fails its type, platform, checksum, executable, or exact-version check.
Each accepted RTK preflight and invocation receives a clean private temporary home, configuration, data, cache, and history location with telemetry, tee recovery, project filters, system/global Git configuration, terminal prompting, and optional Git locks disabled.
The caller cannot weaken those privacy values through ambient environment variables.
The private temporary root is removed after normal completion and caught termination.
The helper logs only its fixed semantic class, selected pin, or a non-sensitive fallback reason, never arguments, patterns, paths, output, command history, or analytics.

A refusal caused by the request shape executes nothing.
An unavailable optional setup discovered before compact execution warns and runs the exact allowlisted raw argv once.
After compact execution starts, the helper returns the observed streams and status and never reruns raw because a result is nonzero, signalled, empty, short, malformed, or suspicious.
This separation avoids executing a child twice while keeping optional-tool unavailability from blocking ordinary work.

## Pin updates and rollback

There is no automatic download, install, discovery, or update path.
A new pin requires a tracked Firstmate change that reviews the exact stable upstream tag and commit, release workflow, dependency and license changes, signing and provenance posture, telemetry and persistence changes, filter and rewrite changes, and relevant open correctness or privacy issues.
Every newly admitted platform must run the adversarial artifact suite on that platform before its checksum joins the helper.
The review must include every allowed verb, hostile filenames and arguments, machine-mode refusals, stdout and stderr, child failures and signals, deterministic behavior, ANSI-only diagnostics, large late diagnostics, privacy isolation, and raw fallback.
Development branches, mutable latest selectors, unpinned Git installs, upstream installers, and the unrelated crates.io `rtk` package are never eligible pins.

Immediate rollback is removing the home-local selection so no task can enter compact execution.
When a prior reviewed pin remains supported, selecting it is the version rollback path.
Artifact cleanup happens only after no home selects that pin.
Rollback never requires a hook uninstall, prompt repair, shell edit, or worker-runtime restart because the pilot installs none of those surfaces.

## Pilot evaluation

The pilot should be evaluated only on non-sensitive task output.
Useful output reduction, immediate raw reruns, missed evidence, unexpected writes or network attempts, and worker confusion are the decision inputs.
Any correctness miss, privacy write outside the private temporary root, unexpected network attempt, or use on a denied class disables the pilot pending review.
Synthetic byte reduction alone is not enough to graduate the feature because output bytes are not provider-billed tokens and compact output can cause compensating raw reruns.

Routine tests use fake raw and RTK executables and make no network call.
`tests/fm-rtk.test.sh` owns fixed mappings, admission, confinement, pin checks, privacy isolation, fallback, and child-outcome coverage.
`tests/fm-rtk-fs-events.test.sh` and `tests/fm-rtk-exec-trace.test.sh` own the lifecycle-inertness guards.
`tests/fm-brief.test.sh` owns generated opt-in, default-off, charter refusal, ordinary safety-text retention, and runtime-neutral brief coverage.
No supported harness or backend needs separate behavior because no command interception is installed and every worker receives the same explicit helper command.
