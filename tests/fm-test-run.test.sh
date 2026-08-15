#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, CI lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"
SUPERVISOR="$ROOT/bin/fm-test-supervisor.py"

assert_present "$SUPERVISOR" "bin/fm-test-supervisor.py is missing"
[ -x "$SUPERVISOR" ] || fail "bin/fm-test-supervisor.py must be executable"
assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$SUPERVISOR" "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-rtk-fs-events.test.sh \
    fm-rtk-exec-trace.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  mkdir -p "$repo/tests/helpers"
  : >"$repo/tests/helpers/fs-event-monitor.py"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/tests/helpers/fs-event-monitor.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-rtk-fs-events.test.sh" "event monitor selects filesystem-event coverage"
  assert_contains "$listed" "tests/fm-rtk-exec-trace.test.sh" "event monitor selects execution-trace coverage"
  git -C "$repo" add tests/helpers/fs-event-monitor.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm event-monitor-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  assert_contains "$out" "FM_TEST_CONTAINMENT mode=developer-non-enforcing enforcement=none" "empty selection containment label"
  assert_contains "$out" "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0" "empty selection summary"
  assert_contains "$out" "FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=0 mode=warn" "empty selection budget summary"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["schema_version"] == 2
assert doc["run"]["complete"] is True
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["scripts"] == []
assert doc["planned"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first tmp rc
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    && fail "portable lanes must not include the real-Herdr focus-flash regression"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    || fail "herdr family must own the real-Herdr focus-flash regression"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-coverage.XXXXXX")
  mkdir -p "$tmp/repo/bin" "$tmp/repo/tests"
  cp "$RUNNER" "$tmp/repo/bin/fm-test-run.sh"
  cp "$SUPERVISOR" "$tmp/repo/bin/fm-test-supervisor.py"
  chmod +x "$tmp/repo/bin/fm-test-supervisor.py"
  cp "$ROOT"/tests/*.test.sh "$tmp/repo/tests/"
  cat >"$tmp/repo/tests/fm-new-required.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$tmp/repo/bin/fm-test-run.sh" "$tmp/repo/tests/fm-new-required.test.sh"
  set +e
  "$tmp/repo/bin/fm-test-run.sh" --check-coverage >"$tmp/missing.out" 2>"$tmp/missing.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "coverage guard accepted a required script without a duration baseline"
  grep -q '^tests/fm-new-required.test.sh$' "$tmp/missing.err" \
    || fail "coverage guard did not identify the required script missing its duration baseline"
  rm -rf "$tmp"

  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_real_herdr_shards_partition_the_family() {
  local lanes count family shard shard_lane listed union dups out
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^real-herdr-gated-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two real-Herdr shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^real-herdr-gated-1of${count}\$" \
    || fail "real-Herdr shard lane names must carry the shard count ${count}: $lanes"

  family=$("$RUNNER" --list --family real-herdr-gated | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="real-herdr-gated-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  # Exactly once: disjoint shards whose union is the whole required family.
  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "real-Herdr shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$family" ] \
    || fail "real-Herdr shards must exactly cover the real-herdr-gated family"

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "real-herdr-gated-1of${count}")" = \
    "$("$RUNNER" --list --lane "real-herdr-gated-1of${count}")" ] \
    || fail "real-Herdr shard membership must be deterministic"

  # The whole-family lane stays available for local operators.
  [ "$("$RUNNER" --list --lane real-herdr-gated | LC_ALL=C sort)" = "$family" ] \
    || fail "the real-herdr-gated lane must still select the whole family"

  # The coverage guard proves the shard partition alongside the serial one.
  out=$("$RUNNER" --check-coverage)
  printf '%s\n' "$out" | grep -q "herdr_shards=${count}" \
    || fail "coverage guard must report the real-Herdr shard count: $out"
  pass "real-Herdr shards are a deterministic disjoint cover of the required family"
}

test_real_herdr_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-herdr-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^real-herdr-gated-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial family: this keeps a CI matrix from silently dropping coverage.
  set +e
  "$RUNNER" --list --lane "real-herdr-gated-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched real-Herdr shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched real-Herdr shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "real-herdr-gated-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range real-Herdr shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane real-herdr-gated-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "real-Herdr shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "real-Herdr shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$SUPERVISOR" "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-supervisor.py"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_ENV_SCHED_WAIT:-}" ]; then
  waited=0
  while [ ! -e "$FM_TEST_ENV_SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$FM_TEST_ENV_SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$FM_TEST_ENV_SCHED_EVIDENCE/slow-done" ]; then
  touch "$FM_TEST_ENV_SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$FM_TEST_ENV_SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" FM_TEST_ENV_SCHED_EVIDENCE="$evidence" FM_TEST_ENV_SCHED_WAIT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  FM_TEST_ENV_SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_default_changed_and_portable_selection() {
  local tmp repo explicit implicit portable all herdr
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-defaults.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '\n' >> "$repo/tests/fm-brief.test.sh"
  explicit=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  implicit=$(cd "$repo" && bin/fm-test-run.sh --list --base HEAD)
  [ "$implicit" = "$explicit" ] || fail "no-mode default diverged from conservative --changed selection"
  [ "$implicit" = tests/fm-brief.test.sh ] || fail "default changed selection was not focused: $implicit"

  portable=$($RUNNER --list --portable | LC_ALL=C sort)
  all=$($RUNNER --list --all | LC_ALL=C sort)
  herdr=$($RUNNER --list --family real-herdr-gated | LC_ALL=C sort)
  [ -n "$portable" ] && [ -n "$herdr" ] || fail "portable or Herdr selection was empty"
  [ "$(comm -12 <(printf '%s\n' "$portable") <(printf '%s\n' "$herdr"))" = "" ] \
    || fail "routine portable selection included real-Herdr integration"
  [ "$(printf '%s\n%s\n' "$portable" "$herdr" | LC_ALL=C sort -u)" = "$all" ] \
    || fail "portable plus required Herdr path must equal complete --all selection"
  rm -rf "$tmp"
  pass "defaults favor changed selection and portable complete excludes required Herdr ownership"
}

make_mixed_runner_fixture() { # <repo> <evidence>
  local repo=$1 evidence=$2 script
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$SUPERVISOR" "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in fm-brief.test.sh fm-composer-lib.test.sh; do
    cat > "$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
name=$(basename "$0" .test.sh)
touch "$FM_TEST_ENV_MIXED_EVIDENCE/$name.started"
other=fm-brief
[ "$name" = fm-brief ] && other=fm-composer-lib
n=0
while [ ! -e "$FM_TEST_ENV_MIXED_EVIDENCE/$other.started" ] && [ "$n" -lt 200 ]; do
  sleep 0.01
  n=$((n + 1))
done
[ -e "$FM_TEST_ENV_MIXED_EVIDENCE/$other.started" ] || exit 9
printf '%s\n' "$name" >> "$FM_TEST_ENV_MIXED_EVIDENCE/counts"
touch "$FM_TEST_ENV_MIXED_EVIDENCE/$name.done"
echo "ok - $name"
SH
  done
  cat > "$repo/tests/fm-daemon.test.sh" <<'SH'
#!/usr/bin/env bash
[ -e "$FM_TEST_ENV_MIXED_EVIDENCE/fm-brief.done" ] || exit 8
[ -e "$FM_TEST_ENV_MIXED_EVIDENCE/fm-composer-lib.done" ] || exit 8
printf '%s\n' fm-daemon >> "$FM_TEST_ENV_MIXED_EVIDENCE/counts"
if [ "${FM_TEST_ENV_MIXED_SERIAL_FAIL:-0}" = 1 ]; then
  echo "not ok - serial failure"
  exit 1
fi
if [ "${FM_TEST_ENV_MIXED_SERIAL_SKIP:-0}" = 1 ]; then
  echo "skip: optional mixed fixture"
  exit 0
fi
echo "ok - serial"
SH
  cat > "$repo/tests/fm-backend-herdr-smoke.test.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_ENV_MIXED_EVIDENCE/herdr-ran"
exit 0
SH
  chmod +x "$repo"/tests/*.test.sh
}

test_mixed_complete_scheduler_exact_once_and_failures() {
  local tmp repo evidence runner rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-mixed.XXXXXX")
  repo="$tmp/repo"
  evidence="$tmp/evidence"
  make_mixed_runner_fixture "$repo" "$evidence"
  runner="$repo/bin/fm-test-run.sh"

  FM_TEST_ENV_MIXED_EVIDENCE="$evidence" "$runner" --portable > "$tmp/out" 2> "$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "mixed portable fixture failed"; }
  [ ! -e "$evidence/herdr-ran" ] || fail "portable mixed scheduler ran real-Herdr family"
  [ "$(LC_ALL=C sort "$evidence/counts")" = "$(printf 'fm-brief\nfm-composer-lib\nfm-daemon')" ] \
    || fail "mixed scheduler did not run every portable script exactly once: $(cat "$evidence/counts")"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0' "$tmp/out" \
    || fail "mixed success summary was wrong: $(grep FM_TEST_SUMMARY "$tmp/out")"

  rm -rf "$evidence"; mkdir -p "$evidence"
  set +e
  FM_TEST_ENV_MIXED_EVIDENCE="$evidence" FM_TEST_ENV_MIXED_SERIAL_FAIL=1 "$runner" --portable > "$tmp/fail.out" 2> "$tmp/fail.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mixed serial functional failure did not propagate"
  grep -q 'FM_TEST_SUMMARY total=3 failed=1' "$tmp/fail.out" \
    || fail "mixed failure summary was wrong: $(grep FM_TEST_SUMMARY "$tmp/fail.out")"

  rm -rf "$evidence"; mkdir -p "$evidence"
  FM_TEST_ENV_MIXED_EVIDENCE="$evidence" FM_TEST_ENV_MIXED_SERIAL_SKIP=1 "$runner" --portable > "$tmp/skip.out" 2> "$tmp/skip.err" \
    || fail "ordinary mixed gate skip should remain successful"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0 skipped_gate=1' "$tmp/skip.out" \
    || fail "mixed gate-skip accounting was wrong: $(grep FM_TEST_SUMMARY "$tmp/skip.out")"
  rm -rf "$tmp"
  pass "mixed complete scheduling is parallel/serial exact-once with failure and gate-skip propagation"
}

make_executor_manifest() { # <manifest> <artifact> <root> <budget-ms:path>...
  local manifest=$1 artifact=$2 root=$3
  shift 3
  python3 - "$manifest" "$artifact" "$root" "$SUPERVISOR" "$@" <<'PY'
import json, os, pathlib, sys, time
manifest, artifact, root, _supervisor, *specs = sys.argv[1:]
scripts = []
for spec in specs:
    budget, path = spec.split(":", 1)
    scripts.append({
        "path": path, "family": "fixture", "expected_gate_skip": "none",
        "duration_baseline_ms": max(1, int(budget) // 2),
        "duration_budget_ms": int(budget), "phase": "serial",
    })
now = int(time.time())
doc = {
    "manifest_version": 2, "artifact": artifact, "root": root,
    "run_id": f"fixture-{os.getpid()}-{time.time_ns()}", "selection": "fixture",
    "jobs": 1, "containment": "developer-non-enforcing",
    "duration_budget_mode": "warn", "fail_on_gate_skip": "",
    "environment": dict(os.environ), "bash": "/bin/bash", "scripts": scripts,
    "deadlines": {
        "t0_epoch": now, "ordinary_epoch": now + 40,
        "terminal_epoch": now + 50, "cleanup_epoch": now + 55,
        "ceiling_epoch": now + 60,
    },
}
pathlib.Path(manifest).write_text(json.dumps(doc), encoding="utf-8")
PY
}

wait_for_started_artifact() { # <artifact>
  local artifact=$1 n=0
  while [ "$n" -lt 500 ]; do
    if python3 - "$artifact" <<'PY' >/dev/null 2>&1
import json, sys
rows = json.load(open(sys.argv[1])).get("scripts", [])
assert rows and any(event.get("name") == "started" for event in rows[0].get("events", []))
PY
    then
      return 0
    fi
    sleep 0.01
    n=$((n + 1))
  done
  return 1
}

test_timeout_then_remaining_exact_once() {
  local tmp manifest artifact rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-timeout.XXXXXX")
  cat >"$tmp/hang.sh" <<'SH'
#!/usr/bin/env bash
printf 'hang\n' >>"$FM_TEST_ENV_EXEC_EVIDENCE"
trap '' TERM
while :; do sleep 1; done
SH
  cat >"$tmp/after.sh" <<'SH'
#!/usr/bin/env bash
printf 'after\n' >>"$FM_TEST_ENV_EXEC_EVIDENCE"
SH
  chmod +x "$tmp"/*.sh
  manifest="$tmp/manifest.json"; artifact="$tmp/artifact.json"
  FM_TEST_ENV_EXEC_EVIDENCE="$tmp/counts" make_executor_manifest "$manifest" "$artifact" "$tmp" \
    "1200:$tmp/hang.sh" "3000:$tmp/after.sh"
  set +e
  FM_TEST_ENV_EXEC_EVIDENCE="$tmp/counts" python3 "$SUPERVISOR" execute --manifest "$manifest" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "timeout fixture unexpectedly passed"
  python3 - "$artifact" "$tmp/counts" <<'PY' || fail "timeout evidence or exact-once coverage is wrong"
import json, pathlib, sys
artifact = json.load(open(sys.argv[1]))
assert [row["terminal"]["result"] for row in artifact["scripts"]] == ["timeout", "passed"]
assert all(row.get("attempt_count") == 1 for row in artifact["scripts"])
assert pathlib.Path(sys.argv[2]).read_text().splitlines() == ["hang", "after"]
PY
  rm -rf "$tmp"
  pass "timeout is terminal red and remaining coverage executes exactly once"
}

test_interruption_and_atomic_evidence() {
  local tmp artifact pid rc n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-interrupt.XXXXXX")
  cat >"$tmp/hang.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$tmp/hang.sh"
  artifact="$tmp/artifact.json"
  "$RUNNER" --json "$artifact" "$tmp/hang.sh" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  wait_for_started_artifact "$artifact" \
    || { kill -KILL "$pid" 2>/dev/null || true; fail "interruption fixture never published started evidence"; }
  n=0
  while [ "$n" -lt 100 ]; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$artifact" \
      || { kill -KILL "$pid" 2>/dev/null || true; fail "atomic artifact polling observed invalid JSON"; }
    n=$((n + 1))
  done
  kill -TERM "$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "catchable interruption exited successfully"
  python3 - "$artifact" <<'PY' || fail "catchable interruption evidence is not terminal and truthful"
import json, sys
artifact = json.load(open(sys.argv[1]))
row = artifact["scripts"][0]
assert row["terminal"]["result"] == "interrupted"
assert artifact["run"]["complete"] is False
assert "active" not in open(sys.argv[1], encoding="utf-8").read()
assert row.get("diagnostic_log")
PY
  rm -rf "$tmp"
  pass "catchable interruption terminalizes after atomic valid snapshots"
}

test_uncatchable_interruption_is_incomplete_red() {
  local tmp manifest artifact pid rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-kill.XXXXXX")
  cat >"$tmp/short.sh" <<'SH'
#!/usr/bin/env bash
sleep 1
SH
  chmod +x "$tmp/short.sh"
  manifest="$tmp/manifest.json"; artifact="$tmp/artifact.json"
  make_executor_manifest "$manifest" "$artifact" "$tmp" "5000:$tmp/short.sh"
  python3 "$SUPERVISOR" execute --manifest "$manifest" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  wait_for_started_artifact "$artifact" \
    || { kill -KILL "$pid" 2>/dev/null || true; fail "uncatchable fixture never published started evidence"; }
  kill -KILL "$pid"
  set +e
  wait "$pid" 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "KILLed executor exited successfully"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$artifact" \
    || fail "KILL left malformed evidence"
  set +e
  python3 "$SUPERVISOR" validate-artifact "$artifact" >"$tmp/validate"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "incomplete KILL evidence validated as complete"
  grep -Fq 'valid=false' "$tmp/validate" || fail "incomplete validator result is missing"
  sleep 1.2
  rm -rf "$tmp"
  pass "uncatchable executor death leaves valid incomplete red evidence"
}

test_required_unsupported_refuses_before_execution() {
  local tmp manifest artifact rc
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skip: unsupported-privilege refusal fixture requires an unprivileged caller\n'
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-refusal.XXXXXX")
  cat >"$tmp/body.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_ENV_REFUSAL_BODY_MARKER"
SH
  chmod +x "$tmp/body.sh"
  manifest="$tmp/manifest.json"; artifact="$tmp/artifact.json"
  FM_TEST_ENV_REFUSAL_BODY_MARKER="$tmp/body-ran" make_executor_manifest \
    "$manifest" "$artifact" "$tmp" "3000:$tmp/body.sh"
  python3 - "$manifest" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
doc["containment"] = "required"
path.write_text(json.dumps(doc))
PY
  set +e
  FM_TEST_ENV_REFUSAL_BODY_MARKER="$tmp/body-ran" python3 "$SUPERVISOR" execute --manifest "$manifest" \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing required privilege became a pass"
  [ ! -e "$tmp/body-ran" ] || fail "unsupported containment executed the test body"
  python3 - "$artifact" <<'PY' || fail "unsupported refusal evidence is incomplete"
import json, sys
artifact = json.load(open(sys.argv[1]))
assert artifact["planned"] and artifact["summary"]["attempted"] == 0
assert artifact["run"]["result"] == "containment_unsupported"
assert artifact["run"]["complete"] is False
assert artifact["containment"]["blocker"]
PY
  rm -rf "$tmp"
  pass "unsupported required containment refuses red before test execution"
}

test_required_platform_qualification() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-qualification.XXXXXX")
  if [ "$(id -u)" -eq 0 ]; then
    python3 "$SUPERVISOR" qualify --artifact "$tmp/qualification.json"
    rc=$?
  elif sudo -n true >/dev/null 2>&1; then
    sudo -n "$(command -v python3)" "$SUPERVISOR" qualify --artifact "$tmp/qualification.json"
    rc=$?
  else
    printf 'skip: privileged platform qualification unavailable; no containment pass claimed\n'
    rm -rf "$tmp"
    return 0
  fi
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "required platform qualification failed"; }
  python3 - "$tmp/qualification.json" <<'PY' || fail "qualification artifact is not a complete pass"
import json, sys
artifact = json.load(open(sys.argv[1]))
assert artifact["complete"] is True and artifact["passed"] is True
assert all(check["passed"] for check in artifact["checks"])
PY
  rm -rf "$tmp"
  pass "required platform qualification proves credential and signal scope"
}

test_environment_isolation_in_serial_and_parallel_children() {
  local tmp repo evidence runner fakebin name
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-env.XXXXXX")
  repo="$tmp/repo"; evidence="$tmp/evidence"; fakebin="$tmp/fakebin"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fakebin"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$SUPERVISOR" "$repo/bin/fm-test-supervisor.py"
  chmod +x "$repo/bin/fm-test-supervisor.py"
  cp "$ROOT/bin/fm-backend.sh" "$repo/bin/fm-backend.sh"
  runner="$repo/bin/fm-test-run.sh"; chmod +x "$runner"
  printf '#!/bin/sh\necho Darwin\n' > "$fakebin/uname"
  printf '#!/bin/sh\nexit 0\n' > "$fakebin/lsappinfo"
  cat > "$fakebin/ps" <<'SH'
#!/bin/sh
case "${2:-}" in
  comm=) printf '%s\n' '/Applications/cmux.app/Contents/MacOS/cmux' ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/lsappinfo" "$fakebin/ps"
  for name in fm-brief fm-daemon; do
    cat > "$repo/tests/$name.test.sh" <<'SH'
#!/usr/bin/env bash
# Fleet routing, an arbitrary non-allowlisted ambient variable, and a
# secret-shaped name must all be absent: the executor builds the child
# environment from an explicit allowlist, so none of these reach the test.
for key in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND \
  TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID __CFBundleIdentifier \
  NOT_ALLOWLISTED_AMBIENT AMBIENT_API_TOKEN FM_TEST_ENV_TOKEN_PROBE; do
  eval "value=\${$key-}"
  [ -z "$value" ] || exit 9
done
# The sanctioned FM_TEST_ENV_ pass-through channel must survive, and PATH must
# be present so the child can still find its tools.
[ "${FM_TEST_ENV_ALLOWED_PROBE-}" = "carried" ] || exit 11
[ -n "${PATH-}" ] || exit 12
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bin/fm-backend.sh"
if PATH="$FM_TEST_ENV_FAKEBIN:$PATH" fm_backend_detect >/dev/null; then
  exit 10
fi
touch "$FM_TEST_ENV_EVIDENCE/$(basename "$0").isolated"
SH
    chmod +x "$repo/tests/$name.test.sh"
  done
  FM_HOME=poison FM_STATE_OVERRIDE=poison FM_DATA_OVERRIDE=poison FM_ROOT_OVERRIDE=poison \
    FM_PROJECTS_OVERRIDE=poison FM_CONFIG_OVERRIDE=poison FM_BACKEND=poison \
    TMUX=poison TMUX_PANE=poison HERDR_ENV=1 HERDR_SESSION=poison \
    HERDR_SOCKET_PATH=poison HERDR_PANE_ID=poison CMUX_WORKSPACE_ID=poison \
    CMUX_SURFACE_ID=poison CMUX_SOCKET_PATH=poison CMUX_TAB_ID=poison \
    CMUX_PANEL_ID=poison __CFBundleIdentifier=com.cmuxterm.app \
    NOT_ALLOWLISTED_AMBIENT=poison AMBIENT_API_TOKEN=poison FM_TEST_ENV_TOKEN_PROBE=poison \
    FM_TEST_ENV_ALLOWED_PROBE=carried \
    FM_TEST_ENV_EVIDENCE="$evidence" FM_TEST_ENV_FAKEBIN="$fakebin" \
    "$runner" --portable > "$tmp/out" 2> "$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "isolated environment fixture failed"; }
  [ -e "$evidence/fm-brief.test.sh.isolated" ] \
    || fail "parallel child did not observe an isolated fleet environment"
  [ -e "$evidence/fm-daemon.test.sh.isolated" ] \
    || fail "serial child did not observe an isolated fleet environment"
  rm -rf "$tmp"
  pass "serial and parallel children isolate ambient fleet routing"
}

test_duration_budget_warns_and_ci_enforces() {
  local tmp repo runner rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"; mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$SUPERVISOR" "$repo/bin/fm-test-supervisor.py"
  runner="$repo/bin/fm-test-run.sh"
  chmod +x "$runner" "$repo/bin/fm-test-supervisor.py"
  cat >"$repo/tests/fm-backend-herdr.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - measured budget fixture"
SH
  cat >"$repo/tests/fm-new-required.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - unmeasured fixture"
SH
  chmod +x "$repo"/tests/*.test.sh

  "$runner" tests/fm-backend-herdr.test.sh >"$tmp/measured.out" 2>"$tmp/measured.err" \
    || fail "measured duration fixture failed"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=1 exceeded=0 missing=0 mode=warn' "$tmp/measured.out" \
    || fail "measured duration summary is missing"

  "$runner" tests/fm-new-required.test.sh >"$tmp/missing-warn.out" 2>"$tmp/missing-warn.err" \
    || fail "local execution must only warn for an unmeasured script"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=1 mode=warn' "$tmp/missing-warn.out" \
    || fail "local execution did not report an explicitly missing measurement"

  set +e
  "$runner" --enforce-duration-budgets tests/fm-new-required.test.sh \
    >"$tmp/missing-enforce.out" 2>"$tmp/missing-enforce.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "enforced execution accepted an unmeasured script"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=1 mode=enforce' "$tmp/missing-enforce.out" \
    || fail "enforced execution did not report the missing measurement"
  rm -rf "$tmp"
  pass "duration inventory warns locally and required execution rejects missing data"
}

test_aggregate_json() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.test.sh" <<'SH'
#!/usr/bin/env bash
echo ok
SH
  cat >"$tmp/b.test.sh" <<'SH'
#!/usr/bin/env bash
echo not-ok
exit 1
SH
  chmod +x "$tmp"/*.test.sh
  "$RUNNER" --json "$tmp/a.json" "$tmp/a.test.sh" >/dev/null 2>"$tmp/a.err" \
    || fail "aggregate passing input fixture failed"
  set +e
  "$RUNNER" --json "$tmp/b.json" "$tmp/b.test.sh" >/dev/null 2>"$tmp/b.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate failing input fixture passed"
  set +e
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate with a failed lane exited successfully"
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=2 failed=1" "aggregate summary line"
  set +e
  "$RUNNER" --aggregate-json "$tmp/reversed.json" "$tmp/b.json" "$tmp/a.json" >/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reversed aggregate with a failed lane exited successfully"
  cmp -s "$tmp/out.json" "$tmp/reversed.json" \
    || { rm -rf "$tmp"; fail "aggregate JSON depends on input order"; }
  python3 - "$tmp/out.json" <<'PY' || fail "aggregate JSON shape is wrong"
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["schema_version"] == 2 and doc["kind"] == "fm-test-aggregate"
assert doc["complete"] is True
assert doc["summary"]["lanes"] == 2 and doc["summary"]["total"] == 2
assert doc["summary"]["failed"] == 1 and len(doc["scripts"]) == 2
PY
  python3 - "$tmp/a.json" "$tmp/incomplete.json" "$tmp/duplicate.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1]))
incomplete = json.loads(json.dumps(source))
incomplete["run"]["complete"] = False
json.dump(incomplete, open(sys.argv[2], "w"))
duplicate = json.loads(json.dumps(source))
duplicate["scripts"][0]["events"].append(dict(duplicate["scripts"][0]["events"][-1]))
json.dump(duplicate, open(sys.argv[3], "w"))
PY
  for bad in "$tmp/incomplete.json" "$tmp/duplicate.json"; do
    set +e
    "$RUNNER" --aggregate-json "$tmp/rejected.json" "$bad" >"$tmp/reject.out" 2>"$tmp/reject.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "aggregate accepted invalid evidence: $bad"
  done
  printf '{"schema_version":1}\n' >"$tmp/unknown.json"
  set +e
  "$RUNNER" --aggregate-json "$tmp/rejected.json" "$tmp/unknown.json" >/dev/null 2>"$tmp/unknown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate accepted an unknown schema"
  rm -rf "$tmp"
  pass "aggregate accepts complete schema-v2 lanes and rejects incomplete, duplicate, or mixed evidence"
}

make_parallel_dev_manifest() { # <manifest> <artifact> <root> <jobs> <budget-ms:path>...
  local manifest=$1 artifact=$2 root=$3 jobs=$4
  shift 4
  python3 - "$manifest" "$artifact" "$root" "$jobs" "$@" <<'PY'
import json, os, pathlib, sys, time
manifest, artifact, root, jobs, *specs = sys.argv[1:]
scripts = []
for spec in specs:
    budget, path = spec.split(":", 1)
    scripts.append({
        "path": path, "family": "fixture", "expected_gate_skip": "none",
        "duration_baseline_ms": max(1, int(budget) // 2),
        "duration_budget_ms": int(budget), "phase": "parallel",
    })
now = int(time.time())
doc = {
    "manifest_version": 2, "artifact": artifact, "root": root,
    "run_id": f"parallel-{os.getpid()}-{time.time_ns()}", "selection": "parallel-fixture",
    "jobs": int(jobs), "containment": "developer-non-enforcing",
    "duration_budget_mode": "warn", "fail_on_gate_skip": "",
    "environment": dict(os.environ), "bash": "/bin/bash", "scripts": scripts,
    "deadlines": {
        "t0_epoch": now, "ordinary_epoch": now + 40,
        "terminal_epoch": now + 50, "cleanup_epoch": now + 55,
        "ceiling_epoch": now + 60,
    },
}
pathlib.Path(manifest).write_text(json.dumps(doc), encoding="utf-8")
PY
}

make_required_fault_manifest() { # <manifest> <artifact> <root> <fault:budget:path>...
  local manifest=$1 artifact=$2 root=$3
  shift 3
  python3 - "$manifest" "$artifact" "$root" "$@" <<'PY'
import json, os, pathlib, sys, time
manifest, artifact, root, *specs = sys.argv[1:]
secret = ("TOKEN", "SECRET", "PASSWORD", "COOKIE", "CREDENTIAL", "AUTHORIZATION", "PRIVATE_KEY")
scripts = []
for spec in specs:
    fault, budget, path = spec.split(":", 2)
    scripts.append({
        "path": path, "family": "fixture", "expected_gate_skip": "none",
        "duration_baseline_ms": max(1, int(budget) // 2),
        "duration_budget_ms": int(budget), "phase": "serial",
        "test_fault": None if fault == "none" else fault,
    })
now = int(time.time())
doc = {
    "manifest_version": 2, "artifact": artifact, "root": root,
    "run_id": f"fault-{os.getpid()}-{time.time_ns()}", "selection": "fault-fixture",
    "jobs": 1, "containment": "required", "duration_budget_mode": "warn",
    "fail_on_gate_skip": "",
    "environment": {
        key: value for key, value in os.environ.items()
        if not any(part in key.upper() for part in secret)
    },
    "bash": "/bin/bash", "scripts": scripts,
    "deadlines": {
        "t0_epoch": now, "ordinary_epoch": now + 40,
        "terminal_epoch": now + 50, "cleanup_epoch": now + 55,
        "ceiling_epoch": now + 60,
    },
}
pathlib.Path(manifest).write_text(json.dumps(doc), encoding="utf-8")
PY
}

test_concurrent_atomic_polling_across_parallel_transitions() {
  local tmp manifest artifact pid rc n i
  local -a specs=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-poll.XXXXXX")
  i=1
  while [ "$i" -le 6 ]; do
    cat >"$tmp/p$i.sh" <<'SH'
#!/usr/bin/env bash
# A short bounded body so the executor cycles started->terminal for several
# scripts concurrently while the artifact is polled from outside.
sleep 0.15
echo "ok - $(basename "$0")"
SH
    chmod +x "$tmp/p$i.sh"
    specs+=("2000:$tmp/p$i.sh")
    i=$((i + 1))
  done
  manifest="$tmp/manifest.json"; artifact="$tmp/artifact.json"
  make_parallel_dev_manifest "$manifest" "$artifact" "$tmp" 4 "${specs[@]}"
  python3 "$SUPERVISOR" execute --manifest "$manifest" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 600 ]; do
    if [ -f "$artifact" ]; then
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$artifact" \
        || { kill -KILL "$pid" 2>/dev/null || true; rm -rf "$tmp"; fail "polling observed invalid JSON during parallel transitions"; }
    fi
    n=$((n + 1))
  done
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "parallel developer run should pass"; }
  python3 - "$artifact" <<'PY' || { rm -rf "$tmp"; fail "final artifact wrong after parallel transitions"; }
import json, pathlib, sys
doc = json.load(open(sys.argv[1]))
assert doc["run"]["complete"] is True, doc["run"]
assert len(doc["scripts"]) == 6
assert all(row["terminal"]["result"] == "passed" for row in doc["scripts"])
assert all(row.get("attempt_count") == 1 for row in doc["scripts"])
# Terminal evidence references only durable diagnostics that survive transient
# cleanup at the end of the run.
for row in doc["scripts"]:
    log_path = row.get("diagnostic_log")
    assert log_path and pathlib.Path(log_path).exists(), log_path
PY
  rm -rf "$tmp"
  pass "concurrent JSON polling stays valid across rapid parallel transitions"
}

test_required_containment_ambiguity_terminalizes() {
  local tmp manifest artifact rc
  local -a py=()
  # A contained caller under NO_NEW_PRIVS cannot escalate, so this self-skips
  # there instead of failing; the dedicated executor-behavior CI job runs it
  # with real privilege on both platforms.
  if [ "$(id -u)" -eq 0 ]; then
    py=("$(command -v python3)")
  elif sudo -n true >/dev/null 2>&1; then
    py=(sudo -n "$(command -v python3)")
  else
    printf 'skip: privileged executor unavailable; no containment_ambiguous claim\n'
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-executor-ambiguous.XXXXXX")
  # Three normally-exiting bodies. The injected cleanup faults, not the process,
  # drive the required-mode ambiguity path: the real KILL still ran and the
  # process really exited, but the executor is forced to treat the domain as
  # unproven (non-quiescent or unreadable probe), so it must quarantine and
  # commit containment_ambiguous with no numeric fallback.
  local name
  for name in ok nq up; do
    cat >"$tmp/$name.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
    chmod +x "$tmp/$name.sh"
  done
  manifest="$tmp/manifest.json"; artifact="$tmp/artifact.json"
  make_required_fault_manifest "$manifest" "$artifact" "$tmp" \
    "none:3000:$tmp/ok.sh" "nonquiescent:3000:$tmp/nq.sh" "unreadable_probe:3000:$tmp/up.sh"
  set +e
  "${py[@]}" "$SUPERVISOR" execute --manifest "$manifest" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "ambiguous containment must be red"; }
  python3 - "$artifact" <<'PY' || { cat "$tmp/err"; rm -rf "$tmp"; fail "containment ambiguity evidence is wrong"; }
import json, pathlib, sys
doc = json.load(open(sys.argv[1]))
rows = doc["scripts"]
results = [row["terminal"]["result"] for row in rows]
assert results == ["passed", "containment_ambiguous", "containment_ambiguous"], results
assert doc["run"]["complete"] is True
assert doc["run"]["result"] == "failed"
# Both faulted identities are quarantined; the passing one is not.
assert len(doc["containment"]["quarantined_uids"]) == 2, doc["containment"]["quarantined_uids"]
assert all(row.get("attempt_count") == 1 for row in rows)
nq, up = rows[1], rows[2]
names = lambda row: [event["name"] for event in row["events"]]
assert "nonquiescence_injected" in names(nq), names(nq)
assert "quiescence_unreadable" in names(up), names(up)
# No numeric fallback: the required cleanup path never signals by PID or group,
# so the terminal must record the ambiguity rather than a kill-by-pid outcome,
# and diagnostics survive the transient cleanup.
for row in (nq, up):
    log_path = row.get("diagnostic_log")
    assert log_path and pathlib.Path(log_path).exists(), log_path
    assert not any(event["name"] == "quiescence" and event.get("proved") for event in row["events"])
PY
  rm -rf "$tmp"
  pass "required non-quiescence and unreadable-probe cleanup terminalize as quarantined containment_ambiguous"
}

ALL_TESTS=(
  test_list_all_exact_suite_coverage
  test_family_selection
  test_single_script_selection
  test_changed_file_selection_is_conservative
  test_changed_dependency_selection_and_unmapped_failure
  test_empty_selection_emits_summary
  test_timing_markers_and_json
  test_aggregate_exit_behavior
  test_gate_skip_accounting
  test_fail_on_gate_skip_token
  test_exclude_family
  test_portable_shard_union_and_coverage_guard
  test_portable_serial_shards_partition_the_serial_lane
  test_portable_serial_shard_lane_refusals
  test_real_herdr_shards_partition_the_family
  test_real_herdr_shard_lane_refusals
  test_jobs_requires_proven_isolated
  test_jobs_parallel_scheduler_and_failure_propagation
  test_default_changed_and_portable_selection
  test_mixed_complete_scheduler_exact_once_and_failures
  test_timeout_then_remaining_exact_once
  test_interruption_and_atomic_evidence
  test_uncatchable_interruption_is_incomplete_red
  test_concurrent_atomic_polling_across_parallel_transitions
  test_required_unsupported_refuses_before_execution
  test_required_containment_ambiguity_terminalizes
  test_required_platform_qualification
  test_environment_isolation_in_serial_and_parallel_children
  test_duration_budget_warns_and_ci_enforces
  test_aggregate_json
)

# Optional targeted subset: FM_TEST_RUN_ONLY="test_a test_b" runs only those,
# used by the cross-platform executor-behavior CI job to exercise the privileged
# executor paths on both required platforms. Unset runs the whole file.
if [ -n "${FM_TEST_RUN_ONLY:-}" ]; then
  for fn in $FM_TEST_RUN_ONLY; do
    declare -F "$fn" >/dev/null || fail "FM_TEST_RUN_ONLY names an unknown test: $fn"
    "$fn"
  done
else
  for fn in "${ALL_TESTS[@]}"; do
    "$fn"
  done
fi
