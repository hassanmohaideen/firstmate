# Firstmate test shards

`bin/fm-test-run.sh` owns behavior-test lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The candidate set came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.
The table keeps those proof timings except for newer focused green measurements documented below.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 46194 | `tests/fm-test-run.test.sh` |
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
| `portable-parallel-1` | 13 | 172276 ms (~172.3 s) |
| `portable-parallel-2` | 11 | 172364 ms (~172.4 s) |
| imbalance | | 88 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

The current 147-script inventory leaves 110 scripts in the portable serial remainder.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints start from the complete per-script measurements in the retained per-shard timing artifacts of green CI run [`31670936022`](https://github.com/hassanmohaideen/firstmate/actions/runs/31670936022) (2026-08-13), with newer focused green measurements replacing stale rows through the procedure below.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of10` | 7 | 252283 ms (~252.3 s) |
| `portable-serial-2of10` | 8 | 252266 ms (~252.3 s) |
| `portable-serial-3of10` | 12 | 252206 ms (~252.2 s) |
| `portable-serial-4of10` | 8 | 252234 ms (~252.2 s) |
| `portable-serial-5of10` | 12 | 252208 ms (~252.2 s) |
| `portable-serial-6of10` | 13 | 252217 ms (~252.2 s) |
| `portable-serial-7of10` | 12 | 252226 ms (~252.2 s) |
| `portable-serial-8of10` | 13 | 252216 ms (~252.2 s) |
| `portable-serial-9of10` | 15 | 252219 ms (~252.2 s) |
| `portable-serial-10of10` | 10 | 252241 ms (~252.2 s) |
| imbalance | | 77 ms |

The single longest measured script, `tests/fm-pr-check-security.test.sh` at 210119 ms in that run, is the floor for any serial shard count.
Ten shards sit just above that floor, so more serial runners would stop paying off without first splitting or speeding that script.

The 2026-08-14 focused baseline refresh used the public runner after concrete fixture and compatibility corrections:

```sh
bin/fm-test-run.sh tests/fm-test-run.test.sh
bin/fm-test-run.sh tests/fm-watcher-lock.test.sh
bin/fm-test-run.sh tests/fm-bootstrap.test.sh
bin/fm-test-run.sh tests/fm-control-relaunch.test.sh
bin/fm-test-run.sh tests/fm-backend-orca.test.sh
bin/fm-test-run.sh tests/fm-calm-pi-extension.test.sh
```

The retained replacement measurements are 46,194 ms, 90,486 ms, 148,695 ms, 85,660 ms, 39,125 ms, and 43,584 ms respectively.
The watcher value is the slower representative-load focused result; unloaded reruns completed in 69,208 ms and 82,072 ms, while retained green CI run [`31745668914`](https://github.com/hassanmohaideen/firstmate/actions/runs/31745668914) completed it in 87,421 ms.

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
The 2026-08-13 recomposition answers each of those: ten balanced serial shards near 221 seconds of hinted work each, two real-Herdr shards, and four lint workers over eight stable shards.
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

## Timing artifacts, budgets, and watchdogs

Portable shards, each portable serial shard, and each real-Herdr shard upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact with deterministic lane and script ordering.
The runner derives a generous per-script duration budget of twice the measured baseline plus ten seconds from the same measured hints used for shard balance and from archived timing artifacts.
The hard per-script watchdog reuses the same measured-baseline owner instead of introducing a second timing inventory.
It allows the greater of two minutes or five measured baselines plus 60 seconds, capped at nine minutes.
Each behavior job records an absolute deadline in its first executable step, before checkout and setup; CI watchdogs further shorten that per-script allowance when necessary to reserve the final 15 seconds for diagnostics, sub-second bounded TERM/KILL cleanup, atomic evidence finalization, and artifact upload before the universal job ceiling. This reserve contains timeout handling without sacrificing a healthy late-shard script when checkout or tool setup is unusually slow.
Local runs without that deadline retain the data-driven per-script allowance.
Every retained healthy baseline fits below its watchdog, including `tests/fm-watcher-lock.test.sh` at 87,421 ms in retained green CI run [`31745668914`](https://github.com/hassanmohaideen/firstmate/actions/runs/31745668914) and 90,486 ms under representative local load.
An unmeasured script has no budget: local execution reports it as missing, enforced execution fails after the functional result, and the coverage guard rejects it from every required lane.
Budget overruns warn during local runs and are enforced by required CI lanes without replacing or hiding functional failures.
A watchdog expiry is always a functional failure and is never retried or converted into a partial pass.
The runner records the active script, begin timestamp, terminal timeout result, elapsed duration, process-tree snapshot, TERM survivors, and KILL survivors in atomically replaced incremental timing JSON before continuing to the next retained script.
It terminates the complete test-owned process tree with bounded TERM/KILL escalation, including descendants that create another process group, so a hung descendant cannot consume the entire job ceiling or leak into another script.
During the TERM grace it repeatedly re-snapshots and retains process identities, so a TERM handler cannot escape cleanup by spawning a new session and recycled PIDs are not signaled as owned processes.
Successful final artifacts retain deterministic script, family, and aggregate ordering.
`.github/workflows/ci.yml` owns the exact artifact names, enforcement wiring, and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact selection flags, lane names, duration enforcement, and bounded scheduling mechanics.

## CI completion target and ceiling

Healthy complete CI targets roughly five to eight minutes from job execution start through required aggregation.
Every CI job has the same explicit ten-minute execution ceiling, including matrix jobs, setup-only guards, lint, invariants, and timing aggregation.
GitHub queue time is outside `timeout-minutes` and does not consume that execution allowance.
The ten-minute ceiling is a universal failure boundary rather than a healthy-duration target, and reaching it fails the job red.
Per-script watchdogs stop one hung behavior script before it can consume the whole ceiling while preserving the complete required inventory, exact-once coverage proof, stateful isolation, real-Herdr coverage, lint, typing, and safety assertions.
