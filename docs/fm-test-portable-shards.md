# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

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

The current 146-script inventory leaves 109 scripts in the portable serial remainder.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints combine the prior green CI artifact with focused 2026-08-13 measurements of the dominant scripts from the reported 1,527-second local run.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 27 | 515445 ms (~515.4 s) |
| `portable-serial-2of4` | 26 | 515445 ms (~515.4 s) |
| `portable-serial-3of4` | 27 | 515455 ms (~515.5 s) |
| `portable-serial-4of4` | 29 | 515462 ms (~515.5 s) |
| imbalance | | 17 ms |

The single longest measured script, `tests/fm-pr-check-security.test.sh` at 194216 ms after its snapshot optimization, is the floor for any shard count.

## Performance evidence

The original complete local `bin/fm-test-run.sh --all` measurement took 1,527 seconds for 146 scripts.
Focused before/after measurements retained from the optimization work are:

| Script | Before | After |
|---|---:|---:|
| `tests/fm-backend-herdr.test.sh` | ~316.7 s | ~37.2 s |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | ~269.6 s | ~238.9 s |
| `tests/fm-pr-check-security.test.sh` | ~268.8 s | ~194.2 s |

Successful run [`31650453019`](https://github.com/hassanmohaideen/firstmate/actions/runs/31650453019) supplied the 2026-08-12 `fm-test-timing-herdr` baselines below except for focus-flash and presentation E2E. Its presentation E2E result was 228,569 ms, not the 238,900 ms focused result in the optimization summary. The raw artifact for that focused result was not retained, so it is not used as a budget baseline.

Presentation E2E was remeasured twice on 2026-08-13 through `/Users/hassanmohaideen/.hassanmohaideen-agent-workspace/bin/fm-herdr-lab.sh` (SHA-256 `3aadae228853e3f8a91199b116b816f18d91df844f1e7bf22b3b6105044ef6d6`) with Herdr 0.8.0 and Treehouse 2.1.1. Both genuine non-default lab runs completed every functional assertion and the default-session tripwire in [261,092 ms](verification/fm-test-timing-herdr-presentation-e2e-2026-08-13.json) and [260,721 ms](verification/fm-test-timing-herdr-presentation-e2e-2026-08-13-rerun.json); the latest result is the budget baseline. Focus-flash was measured separately on macOS aarch64 with Herdr 0.8.0 protocol 19 through the same named helper path.

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

## Timing artifacts and budgets

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact with deterministic lane and script ordering.
The runner derives generous per-script duration budgets from the same measured hints used for shard balance and from archived timing artifacts.
An unmeasured script has no budget: local execution reports it as missing, enforced execution fails after the functional result, and the coverage guard rejects it from every required lane.
Budget overruns warn during local runs and are enforced by required CI lanes without replacing or hiding functional failures.
`.github/workflows/ci.yml` owns the exact artifact names, enforcement wiring, and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact selection flags, lane names, duration enforcement, and bounded scheduling mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | 30 | Each balanced shard is about 8.6 minutes, leaving a generous hang-tripwire margin. |
| Herdr | 75 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
