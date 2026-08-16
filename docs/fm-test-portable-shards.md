# Firstmate test shards

`bin/fm-test-run.sh` owns behavior-test selection, deterministic lane composition, duration inputs, manifest construction, coverage, aggregation, and human-readable output.
`bin/fm-test-supervisor.py` is the single owner of manifest scheduling, attempts, credential-domain containment, deadlines, diagnostics, interruption, cleanup, and durable evidence.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Required containment

Required containment mode leases one otherwise-unused high numeric UID/GID for each selected script after proving that identity absent from account and process credential inventories under a root-owned job-local lock.
The executor remains outside every test identity, releases a blocked child only after permanent credential drop and verification, and uses an unprivileged helper in that exact identity for every signal and quiescence probe.
Numeric PIDs, process groups, mutable ancestry, and environment markers are diagnostics at most and are never cleanup authority in required CI.
The executor is the single owner of the contained child environment and builds it from an explicit default-deny allowlist, so fleet routing, runner secrets, and unknown ambient variables never reach a test and only the sanctioned `FM_TEST_ENV_` channel and a small safe base set pass through.
`bin/fm-test-run.sh` imports that same allowlist when it constructs the manifest, so secrets such as `GITHUB_TOKEN`, `DATABASE_URL`, or `SSH_AUTH_SOCK` are never written to the on-disk manifest that passes through `sudo` to the executor.
Because each leased identity runs its script with the runner-owned checkout as the working directory, the executor grants world read and traverse on the checkout tree except `.git`, read-only, so any leased identity can read the selected script and the files it sources while the tree stays unwritable by tests. Checkout credential persistence is disabled in every leased-test job, so the runner token is never written into the checkout the leased identities can read.
A released child that cannot start its script, for example because of a residual checkout permission problem, reports the exact failing operation on its captured output rather than exiting silently, so the durable per-lane log explains the outcome.
The credential boundary remains stable across fork, exec, parent exit, reparenting, `setsid`, signal handlers, and PID reuse.
An unreadable, ambiguous, or non-quiescent identity is quarantined while later scripts use fresh identities.
Required Linux and macOS qualification fails closed before tests execute when noninteractive privilege, credential inspection, permanent drop, signal scope, or platform semantics are unavailable.
Qualification proves that a live different-UID process is never signaled by its numeric PID during a credential-scoped sweep, and Linux additionally manufactures a true same-numeric-PID reuse in a private PID namespace; macOS relies on the same UID-scoped `kill(-1)` making the numeric PID irrelevant, because deterministic same-number reuse is not available there without exhausting the PID space.
A dedicated per-platform job runs the executor-behavior subset through the public runner on both `ubuntu-latest` and `macos-latest`.
The required public-runner and non-quiescence/ambiguity fixtures self-escalate into credential domains, while timeout, interruption, atomic-evidence, environment-isolation, and scheduling fixtures exercise the same public interfaces in `developer-non-enforcing` mode because their runner-owned scratch is intentionally inaccessible to a leased identity.
Linux currently qualifies the full boundary, including true same-number PID reuse.
Darwin runs the required execute path but its current non-quiescence qualification remains red with bounded survivor-credential, zombie, and probe-errno diagnostics, so it does not yet publish passing containment evidence and is not classified as unsupported.
Local execution is explicitly labeled `developer-non-enforcing`; it does not claim hard descendant containment, and credential-contained CI lanes never accept it.

## Schema-v2 evidence

The executor atomically publishes the complete planned manifest before releasing the first script.
Each attempted script has immutable path, family, and attempt fields, append-preserving events, one historical `started` event, and exactly one terminal object.
There is no durable active result.
A started row without a terminal object remains valid JSON but makes the run incomplete and red after uncatchable executor death.
Every update uses a sibling temporary file, file fsync, atomic replacement, and directory fsync.
Diagnostics are durable before transient files are removed.
Aggregation rejects unknown or mixed schemas, incomplete runs, missing or duplicate attempts, missing or duplicate terminals, and planned/executed inventory mismatch.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

The current 149-script inventory leaves 112 scripts in the portable serial remainder.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The retained per-script measurements come from green CI run [`31670936022`](https://github.com/hassanmohaideen/firstmate/actions/runs/31670936022) (2026-08-13) and are refreshed through the procedure below.
A script added since that run or otherwise lacking a hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of10` | 9 | 227794 ms (~227.8 s) |
| `portable-serial-2of10` | 10 | 227784 ms (~227.8 s) |
| `portable-serial-3of10` | 11 | 227787 ms (~227.8 s) |
| `portable-serial-4of10` | 10 | 227792 ms (~227.8 s) |
| `portable-serial-5of10` | 11 | 227777 ms (~227.8 s) |
| `portable-serial-6of10` | 13 | 227795 ms (~227.8 s) |
| `portable-serial-7of10` | 14 | 227796 ms (~227.8 s) |
| `portable-serial-8of10` | 11 | 227789 ms (~227.8 s) |
| `portable-serial-9of10` | 12 | 227774 ms (~227.8 s) |
| `portable-serial-10of10` | 11 | 227840 ms (~227.8 s) |
| imbalance | | 66 ms |

The single longest measured script, `tests/fm-pr-check-security.test.sh` at 210119 ms in that run, is the floor for any serial shard count.
Ten shards sit just above that floor, so more serial runners would stop paying off without first splitting or speeding that script.

## Real-Herdr CI shards

`real-herdr-gated-<k>of<n>` splits the required real-Herdr family across `n` separate CI runners under the same contract as the serial shards.
Each shard is strictly serial in itself, and each runner provisions its own pinned Herdr, default session, pre-suite snapshot, and cleanup, so the split needs no concurrency isolation proof and every default-session tripwire stays job-local.
`bin/fm-test-run.sh` owns this `n` with the same `of<n>` refusal, `.github/workflows/ci.yml` derives it from `strategy.job-total`, and every shard keeps `--fail-on-gate-skip 'herdr not found'` so a missing pin can never pass as a gate skip.
Assignment reuses the longest-processing-time packing over `real_herdr_duration_hints`.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `real-herdr-gated-1of2` | 1 | 260721 ms (~260.7 s) |
| `real-herdr-gated-2of2` | 12 | 178105 ms (~178.1 s) |

The presentation E2E dominates its shard alone, so its retained measured baseline is the floor for the whole real-Herdr surface at any shard count.

## Performance evidence

The original complete local `bin/fm-test-run.sh --all` measurement took 1,527 seconds for 146 scripts.
Focused before/after measurements retained from the optimization work are:

| Script | Before | Retained after |
|---|---:|---:|
| `tests/fm-backend-herdr.test.sh` | ~316.7 s | ~37.2 s |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | ~269.6 s | ~260.7 s |
| `tests/fm-pr-check-security.test.sh` | ~268.8 s | ~194.2 s |

Successful run [`31650453019`](https://github.com/hassanmohaideen/firstmate/actions/runs/31650453019) supplied the 2026-08-12 `fm-test-timing-herdr` baselines below except for focus-flash and presentation E2E.
Its presentation E2E result was 228,569 ms.
A separate historical observation of about 238.9 seconds has no retained raw artifact and is not treated as measured evidence or used as a budget baseline.

Presentation E2E was remeasured twice on 2026-08-13 through `/Users/hassanmohaideen/.hassanmohaideen-agent-workspace/bin/fm-herdr-lab.sh` (SHA-256 `3aadae228853e3f8a91199b116b816f18d91df844f1e7bf22b3b6105044ef6d6`) with Herdr 0.8.0 and Treehouse 2.1.1.
Both genuine non-default lab runs completed every functional assertion and the default-session tripwire in [261,092 ms](verification/fm-test-timing-herdr-presentation-e2e-2026-08-13.json) and [260,721 ms](verification/fm-test-timing-herdr-presentation-e2e-2026-08-13-rerun.json); the latest result is the current budget baseline.
The artifacts' `duration_baseline_ms` fields faithfully record the provisional 238,900 ms runner setting used during those runs, not another observed duration or the current baseline.
Focus-flash was measured separately on macOS aarch64 with Herdr 0.8.0 protocol 19 through the same named helper path.

| Script | Measured live-path baseline |
|---|---:|
| `tests/fm-afk-inject-herdr-e2e.test.sh` | 61,514 ms |
| `tests/fm-afk-launch.test.sh` | 33,459 ms |
| `tests/fm-backend-autodetect-smoke.test.sh` | 7,678 ms |
| `tests/fm-backend-herdr-eventwait-smoke.test.sh` | 1,703 ms |
| `tests/fm-backend-herdr-focus-flash-e2e.test.sh` | 3,760 ms |
| `tests/fm-backend-herdr-launcher-workspace-e2e.test.sh` | 33,330 ms |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | 260,721 ms |
| `tests/fm-backend-herdr-prune-safety-e2e.test.sh` | 6,385 ms |
| `tests/fm-backend-herdr-respawn-idem-e2e.test.sh` | 2,222 ms |
| `tests/fm-backend-herdr-smoke.test.sh` | 4,699 ms |
| `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh` | 15,487 ms |
| `tests/fm-control-herdr-smoke.test.sh` | 5,821 ms |
| `tests/fm-herdr-session-cleanup-e2e.test.sh` | 2,047 ms |

`real_herdr_duration_hints` retains these measurements for runner-owned CI budgets.

A subsequent portable regression attempt ran for about 1,500 seconds.
Its failures were pre-existing failures unrelated to the scheduling and slow-test optimizations, so the attempt remains classified as incomplete evidence rather than a green regression result or justification to omit coverage.

## CI wall-clock evidence

Green CI run [`31670936022`](https://github.com/hassanmohaideen/firstmate/actions/runs/31670936022) (2026-08-13) completed in 10 minutes 48 seconds of wall-clock at four serial shards.
Its critical path was portable serial shard 2's test step at 10 minutes 18 seconds, with shards 1 and 4 near 9 minutes 35 seconds, the single Herdr lane at 6 minutes 25 seconds, and the full-set lint job at 6 minutes 54 seconds under two bounded workers.
The current composition answers each of those: ten balanced serial shards near 228 seconds of hinted work each, two real-Herdr shards, and four lint workers over eight stable shards.
A local full-set lint measurement on an arm64 host fell from 209.7 seconds at two workers to 126.4 seconds at four workers with byte-identical diagnostics.
The per-lane timing artifacts and aggregate of the next green CI run are the after measurement for this recomposition.
The aggregate now finds nested timing JSON recursively; the prior top-level-only glob silently dropped the Herdr lane from the aggregate artifact.
The floor for the complete run at this composition is the presentation E2E's retained 260,721 ms baseline plus per-job setup and the aggregate tail.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R hassanmohaideen/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It verifies the real-Herdr CI shards the same way against the real-herdr-gated family.

## Timing artifacts and budgets

Portable shards, each portable serial shard, and each real-Herdr shard upload schema-v2 timing JSON with durable per-script diagnostics.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact with deterministic lane and script ordering and complete-evidence validation.
The runner derives generous per-script duration budgets from the measured hints used for shard balance and archived timing artifacts.
An unmeasured script has no budget: local execution reports it as missing, enforced execution fails, and the coverage guard rejects it from every required lane.
Budget overruns warn during local runs and are enforced by required CI lanes without replacing the test's own exit evidence.
The tables above remain scheduling inputs until the next green required run publishes exact final-executor measurements; only those schema-v2 artifacts may refresh them.
`.github/workflows/ci.yml` owns the exact artifact names, enforcement wiring, and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact selection flags, lane names, duration enforcement, and bounded scheduling mechanics.

## Deadlines and reserves

Every workflow job has `timeout-minutes: 10`.
Behavior jobs record T0 as their first executable step, before checkout, so the absolute deadline budget also covers checkout and tool setup rather than starting the clock only once the code is present.
Every behavior lane that invokes the executor passes that one absolute deadline set through the public runner.
Ordinary test allowances end by T0+430 seconds, process diagnostics and terminal evidence end by T0+450 seconds, and job-owned service cleanup ends by T0+480 seconds.
The final 120 seconds remain reserved for artifact upload and platform variance before the 600-second job ceiling.
Terminal publication remains synchronous on the single scheduler thread because adding an I/O thread to a privileged executor that repeatedly forks would introduce fork-time lock hazards.
The executor publishes at most one terminal per scheduler iteration and reserves 15 seconds for every concurrently outstanding terminal, so all terminal evidence is published by T0+450.
Per-attempt deadline enforcement therefore has jitter bounded by one terminal publication's sub-second fsync latency rather than a sub-millisecond guarantee; the required 120-second pre-ceiling margin absorbs that accepted jitter.
The executor reserves startup and cleanup time for every unstarted script and refuses an impossible manifest before execution instead of retrying, skipping, shortening, or truncating coverage.
A timed-out attempt is terminal red, and later required scripts still execute exactly once when their reservations allow.
Healthy complete CI remains targeted at roughly five to eight minutes.
