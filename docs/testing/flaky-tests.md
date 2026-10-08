# Flaky test inventory

This record lists every behavior test that failed intermittently in CI, why it failed, how it was fixed, and whether it could simply be deleted.
It is maintainer verification evidence: dates, run ids, versions, and commands below are exact so a future flake can be compared against them.
CI policy is fixed: no reruns or retry wrappers; a flaky test is fixed at its root cause in the test, the build, or the product.

## Scope and method

The CI window is GitHub Actions for `hassanmohaideen/firstmate` from 2026-08-12 (the first run inside the 60-day window ending 2026-10-06) to 2026-10-06: 207 workflow runs, 155 failed and 21 cancelled jobs, every log read.
A test counts as flaky when it failed and then passed on the same head SHA, failed on a change that did not touch its area, or failed on `main` after a green PR run.
Failures fixed by the next commit on the branch that caused them are genuine regressions and are excluded.
Run ids below are `<run id>-<attempt>` with the portable serial shard as `sN`.

Local reproduction used Linux containers matching `ubuntu-latest` (Ubuntu 24.04, bash 5.2.21), including the real required containment (`FM_TEST_CONTAINMENT=required` with leased UIDs through passwordless `sudo`), under CPU load.
The Docker VM used for this work pauses for 12-18s about once a minute, so wall-clock timeouts seen only locally are not counted as evidence.

## Summary

| Test | CI flakes | Root cause | Status |
|---|---|---|---|
| `fm-watch-triage-wedge` | 3 | watcher ignored or hung on its stop | fixed in this PR |
| `fm-watch-triage-pause` | 7 | watcher hung in exit cleanup on its own lock | fixed earlier (26ab30e) and in this PR |
| `fm-watch-triage` | 5 | same as pause | fixed earlier (26ab30e) and in this PR |
| `fm-watch-triage-events` | 1 | same as pause | fixed earlier (26ab30e) and in this PR |
| `fm-watch-arm` | 2 | arm waited forever on a watcher that ignored its stop | fixed in this PR |
| `fm-secondmate-safety` | 2 | unbounded wait on a watcher stuck in exit cleanup | fixed earlier (26ab30e) and in this PR |
| `fm-watcher-lock` | 3 | unbounded waits on stopped watchers | fixed earlier (acae56d) and in this PR |
| `fm-afk-inject-herdr-e2e` | 7 | away-mode daemon waited forever on its watcher | fixed earlier (94aceeb) |
| `fm-afk-inject-e2e` | 1 | same as afk-inject-herdr-e2e | fixed earlier (94aceeb) |
| `fm-discord-bot` | 11 | fake Gateway crashed; a real refused-connection bug; tight time bounds | fixed in this PR |
| `fm-tmux-agent-liveness` | 6 | tmux server outlived the script | fixed in this PR |
| `fm-remote-job` | 6 | worker startup race; repeated TERM during shutdown | fixed earlier (4eb3138, 960b5c8, 2fb6b71) |
| `fm-inactive-reconcile` | 3 | 1s whole-process budget on a loaded runner | fixed in this PR |
| `fm-procevent` | 0 | fixed 0.5s sleep raced a background claim | fixed in this PR (latent) |

## The watcher stop path

Most watcher-family timeouts share one product defect class: a test, the watch arm, or the away-mode daemon sends TERM to `bin/fm-watch.sh` and waits for it to exit, and the watcher never does.
Three independent causes were found, each with its own fix.

1. **Self-deadlock on the recovery-marker lock (fixed earlier, 26ab30e).**
   A stop landing inside the per-cycle downtime arm check, which holds the wake-queue and recovery-marker locks, ran the exit cleanup, which re-acquires the marker lock and waited on itself forever.
   Regression: `test_stop_inside_marker_lock_exits_and_releases_locks`.
2. **Self-deadlock behind a reclaim guard (fixed in this PR).**
   Reclaiming an abandoned lock holds that lock's `.steal` guard, and every acquisition refuses while a guard exists.
   A stop landing there left the exit cleanup waiting behind a guard the exiting watcher held itself.
   Reproduced deterministically on the PR #35 head: the watcher never exited.
   Fix: `fm_lock_release_owned` releases every lock and guard the exiting process owns before cleanup re-acquires anything, keeping only the singleton lock the recovery transition releases last.
   Regression: `test_stop_holding_marker_steal_guard_exits_and_releases_locks`.
3. **Bash 5.2 loses a trapped TERM (fixed in this PR).**
   When TERM arrives while Bash 5.2 is parsing a `$(...)` command substitution, the trap action itself fails to parse with `trap: line 2: unexpected EOF while looking for matching ')'` and the signal is consumed.
   The watcher keeps polling and anything waiting on it waits forever.
   This is an upstream Bash defect in the same class as the CHLD-trap report on [bug-bash in September 2023](https://lists.libreplanet.org/archive/html/bug-bash/2023-09/msg00058.html); it is present through bash 5.2.37 and absent in 5.3.
   Evidence: a live hang captured in the Linux container had the watcher still polling 22 minutes after its arm forwarded TERM, the arm blocked in `wait`, and exactly that parse error on the watcher's stderr.
   Fix: `fm_stop_trapping_process` in `bin/fm-wake-lib.sh` owns the stop protocol and re-delivers TERM every second until the process is gone, with optional KILL at a deadline.
   The watcher's exit cleanup ignores further stops, so a re-delivered TERM never cuts cleanup short and a genuine cleanup hang still shows as a hang.
   `fm-watch-arm` (child stop, signal handler, restart) and the away-mode daemon use it, and test suites stop watchers and arms through `fm_test_stop_pid` and `fm_test_reap_watcher` in `tests/lib.sh`.
   Regressions: `test_stop_trapping_process_redelivers_a_lost_term` and `test_stop_trapping_process_reports_or_kills_a_survivor`.

Re-delivering a stop is not a test retry: the stop channel itself is lossy on Bash 5.2, so a single TERM is not a valid stop request there, and the same protocol now guards production stops.

Minimal reproduction of cause 3, 300 randomly timed TERMs to a script with `trap 'exit 1' TERM` looping over command substitutions:

| Bash | Lost TERMs |
|---|---|
| 5.2.21 (Ubuntu 24.04, `ubuntu-latest`) | 3 of 300 |
| 5.2.37 (`bash:5.2`, Debian trixie) | 2-5 of 300 |
| 5.1.16, 5.3.20 | 0 of 300 |
| 3.2.57 (macOS) | 0 of 100 |

Backtick substitutions and external commands do not trigger it; every `$(...)` and `<(...)` form tested does.

The same minimal script stopped through the protocol instead of a single TERM, 500 stops each on bash 5.2.21:

| Stop | Trap parse errors | Still running after the stop |
|---|---|---|
| one TERM | 4 | 4 |
| `fm_stop_trapping_process` | 3 | 0 |

Against the real watcher on a busy-pane fixture, 1000 randomly timed single TERMs lost none, so the watcher's per-stop loss rate there is below one in a thousand; the suites stop watchers hundreds of times per CI run, which is why it surfaced as a rare shard failure.

### `tests/fm-watch-triage-wedge.test.sh`

1. **What it tests:** the watcher absorbs a stale but provably working pane, starts a wedge timer, and escalates it past the threshold, including busy panes judged by completed-turn age.
2. **Why it flaked:** `reap` sends TERM and requires exit within 30s; the watcher sometimes never exited.
   CI: 37144870855-1 s6 (2026-10-03, passed attempts 2-4), 37163933404-3 s6 (2026-10-04), and 37241388681-1 s6 on PR #35 (`not ok - watcher pid 22985 did not exit within 30s of TERM` in the default turn-age case).
   The PR #35 head already carried cause 1, and its fixture never holds an abandoned lock, so its remaining hang is cause 3.
   The earlier two were bare per-script timeouts before `reap` was bounded.
3. **Fix options:** a longer wait (hides nothing, fixes nothing); KILL after TERM in the test (skips the cleanup the test relies on); fix the stop path.
   Recommended and done: causes 2 and 3 above, plus a widened 30s wait for cold-start wedge timers and lock and process diagnostics when a stop never completes.
4. **Delete?** No; it is the only coverage of wedge escalation and the busy-turn-age bound.
5. **Status:** fixed in this PR.

### `tests/fm-watch-triage-pause.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-watch-triage-events.test.sh`

1. **What they test:** paused-state suppression and resurfacing, general wake triage, and process-event redrain in the same watcher triage harness.
2. **Why they flaked:** per-script timeouts (exit 124) while `reap` waited, unbounded at the time, on a live watcher.
   Pause: 32316270633-1 s5 (main), 33124868363-1, 33129719727-1, 33132131763-1 and -2 s5, 33566991030-1 s5 (main), 37162446326-2 s5.
   Triage: 31956727688-1 s3, 31992134078-1 s1, 32084806705-1 s1, and two runs on 2026-08-13 cancelled at the old 15-minute ceiling.
   Events: 33944522454-1 s4.
   In each hang the next step was a `reap` of a live watcher; cause 1 was demonstrated for these shards in 26ab30e.
3. **Fix options:** as for the wedge shard; the stop-path fixes cover all three.
4. **Delete?** No; each covers distinct triage behavior.
   This PR's own new pause case, `test_stop_holding_marker_steal_guard_exits_and_releases_locks`, then failed on this PR's CI (37629791974, portable serial 5: "the watcher never reclaimed the abandoned recovery-marker lock").
   When the watcher held the marker lock at plant time, `ln -s` followed the held lock's link and "planted" a stray link inside the watcher's owner directory, so no lock was abandoned (3 of 20 local runs).
   Separately, the shim was armed only after planting, so a reclaim in that gap was never parked (reproduced with a 1.5s pause injected between plant and arm).
   Fixed with `ln -sn` and arming before planting.
5. **Status:** cause 1 fixed earlier in 26ab30e; causes 2 and 3, the three 3s cold-start waits widened to 30s, and the steal-guard case's planting race fixed in this PR.

### `tests/fm-watch-arm.test.sh`

1. **What it tests:** the arm that launches or attaches to a watcher reports the delivered wake, re-surfaces durable work after downtime, and records its lifecycle.
2. **Why it flaked:** 32086064670-1 s10 (main) and 37144870855-1 s6 timed out at a stop-then-`wait` of an arm; the `Killed "$WATCH"` log line is the case's own deliberate kill.
   The arm's own signal handler sent TERM to its watcher and then waited with no bound, so a lost TERM (cause 3) hung both.
   Reproduced in the Linux container (the 22-minute live hang above, in `test_delivery_gap_wake_is_recovered_once`).
3. **Fix options:** bound the test waits only (leaves production arms hanging); fix the arm's stop.
   Done: the arm stops its child through `fm_stop_trapping_process` (15s, then KILL), and every test stop goes through `fm_test_stop_pid`.
   The arm's signal handlers ignore further stops while they run, as the watcher's exit cleanup does, so a re-delivered TERM cannot kill the arm before it stops its child and records `arm-interrupted` (regression: `test_repeated_stop_does_not_cut_arm_stop_short`).
   Two test races surfaced once stops became reliable: the marker-publication-failure case now holds the wake-queue lock so a watcher cycle cannot quarantine its planted marker before the stop lands, and every arm-exit wait uses the suite's 30s deadline instead of 8s.
4. **Delete?** No; it is the only end-to-end coverage of the arm's delivery and recovery contract.
5. **Status:** fixed in this PR.

### `tests/fm-secondmate-safety.test.sh`

1. **What it tests:** secondmate home safety rules; the hanging step checks that an idle secondmate pane is not flagged stale.
2. **Why it flaked:** 32085534595-1 s5 (main) and 37163057959-1 s7 hit the per-script deadline right after the teardown path-boundary matrix case, at a TERM then unbounded `wait` on the watcher.
   Random-TERM stops against `main`'s watcher left one alive after 30s holding its own `.watcher-down.lock` and `.wake-queue.lock` (cause 1); this branch's watcher completed 450 of 450.
3. **Fix options:** as above.
   Done: the case stops the watcher through `fm_test_reap_watcher`.
4. **Delete?** No; it is unique coverage that an idle secondmate is healthy.
5. **Status:** cause 1 fixed earlier (26ab30e); bounded stop with diagnostics in this PR.

### `tests/fm-watcher-lock.test.sh`

1. **What it tests:** the watcher singleton lock, stale-lock reclaim, contention, and arm attach and self-heal behavior.
2. **Why it flaked:** 31818627776-1 and 31822058591-1 s6 (a PR that edited this test) and 31920736258-1 s6 hung to the 30-minute ceiling at unbounded stop-then-wait steps (`test_arm_starts_and_self_heals`, `test_arm_attaches_and_waits_for_live_fresh_watcher`).
   Separately, the two 40-way contention cases held the winning lock for a fixed 1s; a contender starting later than that correctly reclaimed the dead winner's lock and produced two winners.
3. **Fix options:** for the hangs, bound the waits and fix the stop path; for contention, a start barrier.
   Done: acae56d bounded the original two waits; this PR routes the remaining watcher stops through `fm_test_stop_pid`, and the winner now holds the lock until all 40 contenders have attempted.
4. **Delete?** No.
5. **Status:** fixed earlier (acae56d) and in this PR.

### `tests/fm-afk-inject-herdr-e2e.test.sh`, `tests/fm-afk-inject-e2e.test.sh`

1. **What they test:** real away-mode escalation injection through tmux and Herdr.
2. **Why they flaked:** 31566643226, 31570800642 (passed attempt 2), 31578644275, 31646152116, 31652027593, 31672425879, and 31677961515, all 2026-08-12/13, hung silently to the job ceiling while the away-mode daemon waited for its watcher to stop.
3. **Fix options:** bound the daemon's wait.
   Done earlier in 94aceeb (2026-08-13): the daemon sends KILL 2s after TERM; this PR keeps that bound and adds re-delivery through `fm_stop_trapping_process`.
4. **Delete?** No; they are the only real-multiplexer injection coverage.
5. **Status:** fixed earlier (94aceeb); no occurrence after 2026-08-13.

### `tests/fm-discord-bot.test.sh`

1. **What it tests:** the self-hosted Discord bot's Gateway connection through its real service script against a local fake Gateway: reconnects, session resume across restarts, persisted retry delays, terminal suppression, and prompt stops.
2. **Why it flaked:** four messages rotated across 31836467212-1 s9, 31858744908-1 and 31859655815-1 s6, 31922179087-1 s6, 31931601600-1 and -2 s6 (passed attempt 3), 31955144783-1 s6, 31996075621-1 s6 (main), 33124868363-1 s10, 37162599965-1 s10, and 37163933404-1 s10 (passed attempts 2-5).
   - "restarted Gateway did not reconnect": the fake Gateway wrote scheduled frames to sockets already closed, Node raised an unhandled `ERR_STREAM_WRITE_AFTER_END`, and the fake server died; 9 of 36 loaded runs before the fix, each with that trace.
   - That crash exposed a product bug: on Node 22 a refused connection fires `error` but never `close`, so the attempt never settled and the service exited 0 as if stopped, which the LaunchAgent's `SuccessfulExit=false` policy does not restart.
   - "checkpoint replacement process did not preserve Resume" and "fresh process consumed Identify" occurred only before e3c689f, which fixed them; none in more than 100 targeted runs since.
   - "same-boot retry restart did not resume" and the slow-start class: 10s wait deadlines and 1-4s absolute bounds that included a cold Node start.
   - Exit 124 in 33124868363-1 was the script exceeding its old duration budget, since raised.
   - About 45 idle fake servers per run were never stopped, which slowed parallel runs.
3. **Fix options:** a longer reconnect wait (the earlier patch tried 30s and could not help a dead fake server); fix the fake and the bot.
   Done: the fake drops frames for closed sockets and ignores socket errors; the bot settles a connection that errors before opening and falls back to settling 1s after a handshake or ready timeout; positive waits share a 30s deadline; prompt-stop checks assert the bot's own clean `service stopped` record; clock-anomaly bounds are 30s; the repeated-reboot bound starts at the bot's startup marker; fake servers stop when each case passes.
   The terminal-fallback restart case now expects the documented clean stop (exit 0 after `reconnects stopped`), which launchd does not restart; its old check that the process was still running 0.15s after launch held only because Node had not started yet.
   New regression: "refused Gateway connections settle and keep reconnecting", which fails against the old bot on Node 22.
4. **Delete?** No; it is the only behavioral coverage of the bot and it found a real availability bug.
5. **Status:** fixed in this PR; 20 of 20 serial and 20 of 20 in four loaded parallel copies on Linux.
   One earlier loaded batch saw "replacement process did not reconnect" once; it did not recur in 130 later runs, and a recurrence now prints its logs.

### `tests/fm-tmux-agent-liveness.test.sh`

1. **What it tests:** tmux pane liveness classification (alive, dead, ambiguous, missing) against real processes in a private tmux server.
2. **Why it flaked:** every case passed and the script then exited 125, which required containment reports when a passed test leaves processes in its leased domain.
   CI: 31963997526-1 s3, 31992913961-1 s8, 34797428017-1 s5, 37144870855-1 s5, 37153729164-1 s5 (main), 37162446326-1 s5.
   `tmux kill-server` returns once the server accepts the command, so the server and pane processes exited after the script did; they were still alive after 10 of 10 runs, and reaping them sometimes made the executor's quiescence probe fail (4 of 80 loaded runs reproduced exit 125).
3. **Fix options:** rely on b697beb, which stops the probe error being misclassified but leaves the leak; or make the test reap what it starts.
   Done: cleanup records the server and its descendants, kills the server, and waits up to about 10s until none can still run.
4. **Delete?** No; it is the only portable test of the liveness classifier against real processes.
5. **Status:** fixed in this PR; 20 of 20 under real containment with an already empty domain at exit.

### `tests/fm-remote-job.test.sh`

1. **What it tests:** the remote job worker lifecycle: start, ensure, replace, and stop.
2. **Why it flaked:** `remote job worker did not report ready after startup` in 31565141646-1 s4, 31975738241-1 s7 (main), and 31993616728-1 s7 (main); timeouts after `ensure replaces a live worker` in 32086064670-1 s7 (main), 37144870855-3 s2, and 37153729164-1 s2 (main).
3. **Fix options:** fixed at the product level.
4. **Delete?** No.
5. **Status:** fixed earlier: 4eb3138 for startup readiness (every startup failure predates it), and 960b5c8 and 2fb6b71 on the PR #35 branch for repeated TERM and whole-group waits during shutdown (every timeout predates them).

### `tests/fm-inactive-reconcile.test.sh`

1. **What it tests:** the bounded inactive-outcome scan spends at most its budget on a child whose state read hangs, and the next scan resumes at the following child.
2. **Why it flaked:** `not ok - next bounded scan did not resume with the following child` in 31975738241-1 s9 (main), 34006423166-1 s6 (main), and 37163933404-3 s6, each with no wake queue at all.
   The second scan's 1s budget covered process startup, locking, the next child's read, and its queued wake; a loaded runner was cut off after the read but before queueing.
   Reproduced with the exact CI message in 2 of 16 contained shard 6 runs and 11 of 12 loaded parallel runs.
3. **Fix options:** a bigger budget alone (still timing-based); prove the resume by ordering.
   Done: the stalled child's fake reader waits until the following child has been read, so a scan that restarted at the stalled child never reaches the next one under any budget; the second scan gets 10s and the elapsed bounds count the stalled party's own steps instead of wall-clock seconds.
4. **Delete?** No; it is the only coverage of scan resume and budget.
5. **Status:** fixed in this PR; 20 of 20 serial and 12 of 12 loaded parallel, against 1 of 12 before.

### `tests/fm-procevent.test.sh`

1. **What it tests:** the process-to-event runner: one owner per source, one normalized event per completion, and crash recovery.
2. **Why it is flaky:** not observed in CI, but four cases slept 0.5s after `reconcile` started a runner in the background and then asserted ownership; a slower claim lets the test's own duplicate `start` win the claim and block on the source.
3. **Fix:** wait until the public `list` shows a live owner, up to 10s.
4. **Delete?** No.
5. **Status:** fixed in this PR as a latent race.

## Latent hazards not observed in CI

These patterns can plausibly flake on a slow runner but have no CI failure in the window, so they stay open for a later pass rather than being changed here.

- `tests/fm-teardown.test.sh` (grace-spawn cases): a 0.2s sleep before TERM to a perl helper that must already have installed its handler.
- `tests/fm-pr-check-security.test.sh`: about 1-2s for the full arm path to reach staged publication.
- `tests/fm-claude-stop-autoarm.test.sh`: single-flight overlap relies on a fixture `sleep 2`.
- `tests/fm-bootstrap.test.sh`: a fake clock that advances 1s per 10ms of real time.
- `tests/fm-wake-queue.test.sh`: a fixed 3s enrichment delay window.
- `tests/fm-test-run.test.sh`: a fixture `sleep 1` is the only window between started evidence and the KILL.
- `fm-watch-arm`, `fm-watch-triage-pause`, and `fm-watch-triage-wedge` assertion windows, and the arm's 10s confirmation default, failed only when several serial-lane files shared one machine's CPU; CI runs them strictly serially.
- Seen only in this work's local Linux container, with no CI occurrence: `fm-daemon` "a hung wedge notifier override blocked the alarm for 17-19s" (bound 6s) and `fm-watch-triage-events` "beacon went stale while absorbing (age 14s)", both the length of the container VM's periodic 12-18s pauses.
- `fm-afk-inject-e2e` fails deterministically in a container with no `LANG` set, because the away-mode digest begins with U+2063; GitHub runners use a UTF-8 locale, and it passes with `LANG=C.UTF-8`.
- Fixed-sleep negative checks (`fm-procevent`, `fm-remote-backlog-handoff`, `fm-remote-secondmate-lifecycle-e2e`, `fm-remote-job`, `fm-busy-state`) cannot flake but lose coverage on a slow runner.

## Still open

- `fm-watcher-lock` `test_arm_propagates_immediate_wake_before_confirmation`: one silent watcher exit 1 during a contained shard 10 run on this branch, not seen in CI and not reproduced in 60 isolated runs.
  The watcher printed nothing, which leaves its silent `exit 1` paths; the leading candidate is custom-check cleanup giving up when the check's process group is still visible about 1s after KILL.
  The next occurrence should be read with the watcher's stderr and the cycle-exit ledger before changing code.

## Deletion candidates

No test was deleted: every flaky test above is the only coverage of its behavior.

## CI failures not tied to a test

- The timing aggregate failed on every partial rerun (34797428017-2, 37144870855-2, 37162446326-3, 37163933404-2 and -4) because an earlier attempt's failed lane evidence was still counted; b697beb aggregates only the newest attempt of each lane.
- Two duration-budget overruns by untouched scripts (31675731406-1, 31676776201-1) were runner speed variance.
- Five "PR must be raised via no-mistakes" failures were PR descriptions missing the marker.

## Test isolation

`tests/home-isolation.sh`, sourced by every shell suite through `tests/lib.sh`, drops inherited home routing (`FM_HOME`, `FM_*_OVERRIDE`, `FM_*_HOME`, `FM_*_ROOT`) since caaa8c3, so a direct run resolves what contained CI resolves.
Contained CI additionally gives each script a private `HOME` and `TMPDIR` under a leased UID.
Remaining gaps affect direct local runs, not CI flakiness: `HOME`-relative defaults such as the process-event claim root under `~/.local/state/firstmate/procevent-claims` are reached by suites that do not set `FM_PROCEVENT_CLAIM_ROOT`, and multiplexer variables such as `TMUX` are inherited.

## Reproducing

The commands below are the ones used for this record, run from the repository root.

- One shard as CI runs it: `FM_TEST_CONTAINMENT=required bin/fm-test-run.sh --lane portable-serial-6of10 --enforce-duration-budgets` in an Ubuntu 24.04 container with passwordless `sudo`.
- Twenty serial runs of a file, each under a hard limit: `for i in $(seq 1 20); do timeout -k 5 300 bash tests/<file>.test.sh || echo "run $i failed"; done`.
- Bash 5.2 signal loss: run a script with `trap 'exit 1' TERM` in a `while :; do x=$(printf hi); done` loop and send it TERM at random moments under `bash:5.2`; a lost TERM leaves the script running and prints the trap parse error.

## Proof runs for this PR

All runs used Linux containers on bash 5.2.21, each file serially with a hard 300s limit per run, at this branch's committed head.
Containers used Node 22 and a UTF-8 locale where the suite needs them, as GitHub's runners do.

| Test file | Serial runs passed |
|---|---|
| `fm-watch-triage-wedge` | 20 of 20 |
| `fm-watch-triage-pause` | 20 of 20 |
| `fm-watch-triage` | 20 of 20 |
| `fm-watch-triage-events` | 18 of 20; both failures were 14s and 18s host pauses (see latent hazards) |
| `fm-watch-arm` | 20 of 20 after its two race fixes (19 of 20 before each) |
| `fm-watcher-lock` | 20 of 20 |
| `fm-secondmate-safety` | 20 of 20 |
| `fm-tmux-agent-liveness` | 20 of 20, plus 20 of 20 under required containment |
| `fm-inactive-reconcile` | 20 of 20, plus 12 of 12 loaded parallel |
| `fm-procevent` | 20 of 20 |
| `fm-discord-bot` | 20 of 20, plus 20 of 20 in four loaded parallel copies |
| `fm-afk-inject-e2e` | 20 of 20 |
| `fm-daemon` | 17 of 20; all three failures were 17-19s host pauses in one alarm-bound case (see latent hazards) |

The `fm-watch-triage-pause` steal-guard planting fix came after the runs above, from CI run 37629791974.
Its case passed 25 of 25 serial runs on macOS, against 3 of 20 before the fix, and the whole file then passed.

CI shard layout: portable serial shards 4, 5, 6, 7, and 9 of 10 passed in one run each under `FM_TEST_CONTAINMENT=required` with `--enforce-duration-budgets`.
Shard 10 failed once in `fm-watcher-lock` (`arm returned non-zero for an immediate wake ... watcher cycle exited 1 without an actionable reason`); that case then passed 60 of 60 in isolation and the whole file 20 of 20, so it stays open below.
