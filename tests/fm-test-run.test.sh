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
  [ "$out" = "$(printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\nFM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=0 mode=warn')" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_budget_exceeded": 0, "duration_budget_missing": 0, "duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
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
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false result=passed$' "$out" \
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
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true result=passed$' "$out" \
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
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
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
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
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
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
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
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true result=passed$' "$tmp/out6" \
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
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in fm-brief.test.sh fm-composer-lib.test.sh; do
    cat > "$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
name=$(basename "$0" .test.sh)
touch "$MIXED_EVIDENCE/$name.started"
other=fm-brief
[ "$name" = fm-brief ] && other=fm-composer-lib
n=0
while [ ! -e "$MIXED_EVIDENCE/$other.started" ] && [ "$n" -lt 200 ]; do
  sleep 0.01
  n=$((n + 1))
done
[ -e "$MIXED_EVIDENCE/$other.started" ] || exit 9
printf '%s\n' "$name" >> "$MIXED_EVIDENCE/counts"
touch "$MIXED_EVIDENCE/$name.done"
echo "ok - $name"
SH
  done
  cat > "$repo/tests/fm-daemon.test.sh" <<'SH'
#!/usr/bin/env bash
[ -e "$MIXED_EVIDENCE/fm-brief.done" ] || exit 8
[ -e "$MIXED_EVIDENCE/fm-composer-lib.done" ] || exit 8
printf '%s\n' fm-daemon >> "$MIXED_EVIDENCE/counts"
if [ "${MIXED_SERIAL_FAIL:-0}" = 1 ]; then
  echo "not ok - serial failure"
  exit 1
fi
if [ "${MIXED_SERIAL_SKIP:-0}" = 1 ]; then
  echo "skip: optional mixed fixture"
  exit 0
fi
echo "ok - serial"
SH
  cat > "$repo/tests/fm-backend-herdr-smoke.test.sh" <<'SH'
#!/usr/bin/env bash
touch "$MIXED_EVIDENCE/herdr-ran"
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

  MIXED_EVIDENCE="$evidence" "$runner" --portable > "$tmp/out" 2> "$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "mixed portable fixture failed"; }
  [ ! -e "$evidence/herdr-ran" ] || fail "portable mixed scheduler ran real-Herdr family"
  [ "$(LC_ALL=C sort "$evidence/counts")" = "$(printf 'fm-brief\nfm-composer-lib\nfm-daemon')" ] \
    || fail "mixed scheduler did not run every portable script exactly once: $(cat "$evidence/counts")"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0' "$tmp/out" \
    || fail "mixed success summary was wrong: $(grep FM_TEST_SUMMARY "$tmp/out")"

  rm -rf "$evidence"; mkdir -p "$evidence"
  set +e
  MIXED_EVIDENCE="$evidence" MIXED_SERIAL_FAIL=1 "$runner" --portable > "$tmp/fail.out" 2> "$tmp/fail.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mixed serial functional failure did not propagate"
  grep -q 'FM_TEST_SUMMARY total=3 failed=1' "$tmp/fail.out" \
    || fail "mixed failure summary was wrong: $(grep FM_TEST_SUMMARY "$tmp/fail.out")"

  rm -rf "$evidence"; mkdir -p "$evidence"
  MIXED_EVIDENCE="$evidence" MIXED_SERIAL_SKIP=1 "$runner" --portable > "$tmp/skip.out" 2> "$tmp/skip.err" \
    || fail "ordinary mixed gate skip should remain successful"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0 skipped_gate=1' "$tmp/skip.out" \
    || fail "mixed gate-skip accounting was wrong: $(grep FM_TEST_SUMMARY "$tmp/skip.out")"
  rm -rf "$tmp"
  pass "mixed complete scheduling is parallel/serial exact-once with failure and gate-skip propagation"
}

test_parallel_signal_cleanup() {
  local tmp repo evidence runner pid child rc n watchdog
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-signal.XXXXXX")
  repo="$tmp/repo"; evidence="$tmp/evidence"; mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"; runner="$repo/bin/fm-test-run.sh"; chmod +x "$runner"
  cat > "$repo/tests/fm-brief.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT HUP
sleep 300 &
printf '%s\n' "$!" > "$SIGNAL_EVIDENCE/child.pid"
touch "$SIGNAL_EVIDENCE/fm-brief.ready"
wait
SH
  cat > "$repo/tests/fm-composer-lib.test.sh" <<'SH'
#!/usr/bin/env bash
cleanup() { touch "$SIGNAL_EVIDENCE/fm-composer-lib.cleaned"; exit 143; }
trap cleanup TERM INT HUP
touch "$SIGNAL_EVIDENCE/fm-composer-lib.ready"
while :; do sleep 1; done
SH
  chmod +x "$repo"/tests/*.test.sh
  SIGNAL_EVIDENCE="$evidence" "$runner" --jobs 2 \
    tests/fm-brief.test.sh tests/fm-composer-lib.test.sh > "$tmp/out" 2> "$tmp/err" &
  pid=$!
  n=0
  while { [ ! -e "$evidence/fm-brief.ready" ] || [ ! -e "$evidence/fm-composer-lib.ready" ]; } && [ "$n" -lt 300 ]; do
    sleep 0.01
    n=$((n + 1))
  done
  [ -e "$evidence/fm-brief.ready" ] && [ -e "$evidence/fm-composer-lib.ready" ] \
    || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$tmp"; fail "parallel cleanup fixtures never started"; }
  child=$(cat "$evidence/child.pid")
  kill -TERM "$pid"
  (
    sleep 5
    if kill -0 "$pid" 2>/dev/null; then
      touch "$evidence/cleanup-timed-out"
      kill -KILL "$child" 2>/dev/null || true
    fi
  ) &
  watchdog=$!
  set +e
  wait "$pid"
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  set -e
  [ ! -e "$evidence/cleanup-timed-out" ] || fail "interrupted runner hung on a TERM-resistant descendant"
  [ "$rc" -ne 0 ] || fail "interrupted runner exited successfully"
  [ -e "$evidence/fm-composer-lib.cleaned" ] \
    || fail "interrupted runner did not run the trapping fixture cleanup"
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "interrupted runner left a non-trapping fixture child alive"
  fi
  rm -rf "$tmp"
  pass "parallel signal cleanup terminates and waits for every active process tree"
}

test_serial_signal_cleanup() {
  local tmp repo evidence runner pid child rc n watchdog
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-serial-signal.XXXXXX")
  repo="$tmp/repo"; evidence="$tmp/evidence"; mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"; runner="$repo/bin/fm-test-run.sh"; chmod +x "$runner"
  cat >"$repo/tests/fm-daemon.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT HUP
sleep 300 &
printf '%s\n' "$!" >"$SIGNAL_EVIDENCE/child.pid"
touch "$SIGNAL_EVIDENCE/ready"
wait
SH
  chmod +x "$repo/tests/fm-daemon.test.sh"
  SIGNAL_EVIDENCE="$evidence" "$runner" tests/fm-daemon.test.sh >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  n=0
  while [ ! -e "$evidence/ready" ] && [ "$n" -lt 300 ]; do
    sleep 0.01
    n=$((n + 1))
  done
  [ -e "$evidence/ready" ] \
    || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$tmp"; fail "serial cleanup fixture never started"; }
  child=$(cat "$evidence/child.pid")
  kill -TERM "$pid"
  (
    sleep 5
    if kill -0 "$pid" 2>/dev/null; then
      touch "$evidence/cleanup-timed-out"
      kill -KILL "$child" 2>/dev/null || true
    fi
  ) &
  watchdog=$!
  set +e
  wait "$pid"
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  set -e
  [ ! -e "$evidence/cleanup-timed-out" ] || fail "interrupted serial runner hung on a TERM-resistant descendant"
  [ "$rc" -ne 0 ] || fail "interrupted serial runner exited successfully"
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "interrupted serial runner left a TERM-resistant descendant alive"
  fi
  rm -rf "$tmp"
  pass "serial signal cleanup terminates and waits for its complete process group"
}

test_completed_worker_descendant_cleanup() {
  local mode tmp repo evidence runner pid child rc n watchdog
  for mode in serial parallel; do
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-completed-group.XXXXXX")
    repo="$tmp/repo"; evidence="$tmp/evidence"; mkdir -p "$repo/bin" "$repo/tests" "$evidence"
    cp "$RUNNER" "$repo/bin/fm-test-run.sh"; runner="$repo/bin/fm-test-run.sh"; chmod +x "$runner"
    cat >"$repo/tests/fm-brief.test.sh" <<'SH'
#!/usr/bin/env bash
bash -c 'trap "" TERM INT HUP; touch "$SIGNAL_EVIDENCE/descendant.ready"; while :; do sleep 1; done' \
  >/dev/null 2>&1 &
printf '%s\n' "$!" >"$SIGNAL_EVIDENCE/descendant.pid"
n=0
while [ ! -e "$SIGNAL_EVIDENCE/descendant.ready" ] && [ "$n" -lt 300 ]; do
  sleep 0.01
  n=$((n + 1))
done
[ -e "$SIGNAL_EVIDENCE/descendant.ready" ] || exit 9
exit 0
SH
    cat >"$repo/tests/fm-composer-lib.test.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM INT HUP
touch "$SIGNAL_EVIDENCE/blocker.ready"
while :; do sleep 1; done
SH
    chmod +x "$repo"/tests/*.test.sh
    set -- tests/fm-brief.test.sh tests/fm-composer-lib.test.sh
    [ "$mode" = parallel ] && set -- --jobs 2 "$@"
    SIGNAL_EVIDENCE="$evidence" "$runner" "$@" >"$tmp/out" 2>"$tmp/err" &
    pid=$!
    n=0
    while { [ ! -e "$evidence/blocker.ready" ] || ! grep -q 'FM_TEST_END .*tests/fm-brief.test.sh' "$tmp/out" 2>/dev/null; } \
      && [ "$n" -lt 500 ]; do
      sleep 0.01
      n=$((n + 1))
    done
    if [ ! -e "$evidence/blocker.ready" ] || ! grep -q 'FM_TEST_END .*tests/fm-brief.test.sh' "$tmp/out" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -rf "$tmp"
      fail "$mode completed-group fixture never reached its interruptible state"
    fi
    child=$(cat "$evidence/descendant.pid")
    kill -TERM "$pid"
    (
      sleep 5
      if kill -0 "$pid" 2>/dev/null; then
        touch "$evidence/cleanup-timed-out"
        kill -KILL "$child" 2>/dev/null || true
      fi
    ) &
    watchdog=$!
    set +e
    wait "$pid"
    rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    set -e
    [ "$rc" -ne 0 ] || fail "$mode interrupted runner exited successfully"
    [ ! -e "$evidence/cleanup-timed-out" ] \
      || fail "$mode cleanup hung on a completed worker's TERM-resistant descendant"
    if kill -0 "$child" 2>/dev/null; then
      kill -KILL "$child" 2>/dev/null || true
      fail "$mode cleanup lost a completed worker's TERM-resistant descendant"
    fi
    rm -rf "$tmp"
  done
  pass "completed worker groups remain owned through serial and parallel interruption"
}

test_environment_isolation_in_serial_and_parallel_children() {
  local tmp repo evidence runner fakebin name
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-env.XXXXXX")
  repo="$tmp/repo"; evidence="$tmp/evidence"; fakebin="$tmp/fakebin"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fakebin"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
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
for key in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND \
  TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID __CFBundleIdentifier; do
  eval "value=\${$key-}"
  [ -z "$value" ] || exit 9
done
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bin/fm-backend.sh"
if PATH="$ENV_FAKEBIN:$PATH" fm_backend_detect >/dev/null; then
  exit 10
fi
touch "$ENV_EVIDENCE/$(basename "$0").isolated"
SH
    chmod +x "$repo/tests/$name.test.sh"
  done
  FM_HOME=poison FM_STATE_OVERRIDE=poison FM_DATA_OVERRIDE=poison FM_ROOT_OVERRIDE=poison \
    FM_PROJECTS_OVERRIDE=poison FM_CONFIG_OVERRIDE=poison FM_BACKEND=poison \
    TMUX=poison TMUX_PANE=poison HERDR_ENV=1 HERDR_SESSION=poison \
    HERDR_SOCKET_PATH=poison HERDR_PANE_ID=poison CMUX_WORKSPACE_ID=poison \
    CMUX_SURFACE_ID=poison CMUX_SOCKET_PATH=poison CMUX_TAB_ID=poison \
    CMUX_PANEL_ID=poison __CFBundleIdentifier=com.cmuxterm.app \
    ENV_EVIDENCE="$evidence" ENV_FAKEBIN="$fakebin" \
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
  local tmp repo runner fakebin real_python rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"; fakebin="$tmp/fakebin"; mkdir -p "$repo/bin" "$repo/tests" "$fakebin"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"; runner="$repo/bin/fm-test-run.sh"; chmod +x "$runner"
  cat > "$repo/tests/fm-backend-herdr.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - measured budget fixture"
SH
  cat > "$repo/tests/fm-backend-herdr-smoke.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - measured real-Herdr fixture"
SH
  cat > "$repo/tests/fm-new-required.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - unmeasured fixture"
SH
  cat > "$repo/tests/fm-afk-inject-herdr-e2e.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - long measured Herdr fixture"
SH
  cat > "$repo/tests/fm-backend-herdr-focus-flash-e2e.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - measured focus-flash fixture"
SH
  chmod +x "$repo"/tests/*.test.sh
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -c ] && printf '%s' "\${2:-}" | grep -Fq 'time.time()'; then
  n=0
  [ ! -f '$tmp/clock' ] || n=\$(cat '$tmp/clock')
  n=\$((n + 1)); printf '%s\n' "\$n" > '$tmp/clock'
  case "\$n" in 1|2) echo 0 ;; *) echo "\${FAKE_DURATION_MS:-200000}" ;; esac
  exit 0
fi
exec '$real_python' "\$@"
SH
  chmod +x "$fakebin/python3"

  PATH="$fakebin:$PATH" "$runner" tests/fm-backend-herdr.test.sh > "$tmp/warn.out" 2> "$tmp/warn.err" \
    || fail "local duration budget warning must not fail a functional pass"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=1 exceeded=1 missing=0 mode=warn' "$tmp/warn.out" \
    || fail "local duration budget warning summary was missing"
  grep -q 'duration budget exceeded:' "$tmp/warn.err" || fail "duration overrun was not actionable"

  rm -f "$tmp/clock"
  set +e
  PATH="$fakebin:$PATH" "$runner" --enforce-duration-budgets \
    tests/fm-backend-herdr.test.sh > "$tmp/enforce.out" 2> "$tmp/enforce.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "CI duration budget enforcement did not fail"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/enforce.out" \
    || fail "duration enforcement hid or rewrote the functional result"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=1 exceeded=1 missing=0 mode=enforce' "$tmp/enforce.out" \
    || fail "duration enforcement summary was missing"

  rm -f "$tmp/clock"
  PATH="$fakebin:$PATH" "$runner" tests/fm-new-required.test.sh > "$tmp/missing-warn.out" 2> "$tmp/missing-warn.err" \
    || fail "local execution must only warn for an unmeasured script"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=1 mode=warn' "$tmp/missing-warn.out" \
    || fail "local execution did not report an explicitly missing measurement"
  grep -q 'duration budget missing:' "$tmp/missing-warn.err" \
    || fail "missing local duration measurement was not actionable"

  rm -f "$tmp/clock"
  set +e
  PATH="$fakebin:$PATH" "$runner" --enforce-duration-budgets \
    tests/fm-new-required.test.sh > "$tmp/missing-enforce.out" 2> "$tmp/missing-enforce.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "enforced execution accepted an unmeasured script"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/missing-enforce.out" \
    || fail "missing-budget enforcement hid the functional result"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=1 mode=enforce' "$tmp/missing-enforce.out" \
    || fail "enforced execution did not report the missing measurement"

  rm -f "$tmp/clock"
  FAKE_DURATION_MS=65000 PATH="$fakebin:$PATH" "$runner" --enforce-duration-budgets \
    tests/fm-afk-inject-herdr-e2e.test.sh > "$tmp/herdr.out" 2> "$tmp/herdr.err" \
    || fail "measured long Herdr duration was rejected by the default fallback budget"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=1 exceeded=0 missing=0 mode=enforce' "$tmp/herdr.out" \
    || fail "long Herdr duration did not use its measured budget"

  rm -f "$tmp/clock"
  FAKE_DURATION_MS=17520 PATH="$fakebin:$PATH" "$runner" --enforce-duration-budgets \
    tests/fm-backend-herdr-focus-flash-e2e.test.sh > "$tmp/focus.out" 2> "$tmp/focus.err" \
    || fail "measured focus-flash budget rejected its inclusive boundary"
  grep -q 'FM_TEST_BUDGET_SUMMARY checked=1 exceeded=0 missing=0 mode=enforce' "$tmp/focus.out" \
    || fail "focus-flash duration did not use its measured real-Herdr budget"
  rm -rf "$tmp"
  pass "duration budgets warn locally and enforce every required CI script"
}

test_watchdog_timeout_cleanup_and_incremental_evidence() {
  local tmp repo runner evidence pid child rc n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-watchdog.XXXXXX")
  repo="$tmp/repo"; evidence="$tmp/evidence"; mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  runner="$repo/bin/fm-test-run.sh"
  chmod +x "$runner"
  cat >"$repo/tests/fm-watcher-lock.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >>"$WATCHDOG_EVIDENCE/watchdog-runs"
trap '' TERM INT HUP
bash -c 'trap "" TERM INT HUP; while :; do sleep 1; done' &
printf '%s\n' "$!" >"$WATCHDOG_EVIDENCE/descendant.pid"
touch "$WATCHDOG_EVIDENCE/watchdog-started"
wait
SH
  cat >"$repo/tests/fm-new-required.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >>"$WATCHDOG_EVIDENCE/followup-runs"
touch "$WATCHDOG_EVIDENCE/followup-started"
while [ ! -e "$WATCHDOG_EVIDENCE/release-followup" ]; do sleep 0.01; done
echo 'ok - followup after timeout'
SH
  chmod +x "$repo"/tests/*.test.sh

  WATCHDOG_EVIDENCE="$evidence" FM_TEST_WATCHDOG_SECONDS_OVERRIDE=1 \
    "$runner" --json "$tmp/timing.json" \
    tests/fm-watcher-lock.test.sh tests/fm-new-required.test.sh >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  n=0
  while [ ! -e "$evidence/followup-started" ] && [ "$n" -lt 500 ]; do
    sleep 0.01
    n=$((n + 1))
  done
  [ -e "$evidence/followup-started" ] || {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$tmp"
    fail "watchdog did not terminate the hung script and continue"
  }
  [ -f "$tmp/timing.json" ] || fail "timeout did not persist incremental timing evidence"
  python3 -c '
import json, sys
row = json.load(open(sys.argv[1]))["scripts"]
assert len(row) == 1, row
row = row[0]
assert row["path"] == "tests/fm-watcher-lock.test.sh", row
assert row["result"] == "timeout" and row["exit"] == 124, row
assert row["began_at"].endswith("Z") and row["duration_ms"] >= 1000, row
assert any("active_script=tests/fm-watcher-lock.test.sh" in line for line in row["timeout_diagnostics"]), row
assert any("processes_surviving_kill:" in line for line in row["timeout_diagnostics"]), row
' "$tmp/timing.json" || fail "incremental timeout artifact lacks actionable evidence"
  touch "$evidence/release-followup"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a watchdog timeout must fail the run"
  [ "$(wc -l <"$evidence/watchdog-runs" | tr -d ' ')" = 1 ] \
    || fail "timed-out script was silently rerun"
  [ "$(wc -l <"$evidence/followup-runs" | tr -d ' ')" = 1 ] \
    || fail "post-timeout coverage did not run exactly once"
  grep -Eq '^FM_TEST_BEGIN .+ tests/fm-watcher-lock.test.sh ' "$tmp/out" \
    || fail "timeout output lost FM_TEST_BEGIN"
  grep -Eq '^FM_TEST_END .+ tests/fm-watcher-lock.test.sh exit=124 duration_ms=[0-9]+ gate_skip=false result=timeout$' "$tmp/out" \
    || fail "timeout output lost the terminal result"
  grep -Fq 'FM_TEST_TIMEOUT_DIAGNOSTIC tests/fm-watcher-lock.test.sh active_script=tests/fm-watcher-lock.test.sh' "$tmp/err" \
    || fail "timeout diagnostics did not name the exact active script"
  child=$(cat "$evidence/descendant.pid")
  n=0
  while kill -0 "$child" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.01; n=$((n + 1)); done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "watchdog left a test-owned descendant alive"
  fi
  python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["scripts"]
assert [row["path"] for row in rows] == ["tests/fm-new-required.test.sh", "tests/fm-watcher-lock.test.sh"], rows
assert [row["result"] for row in rows] == ["passed", "timeout"], rows
' "$tmp/timing.json" || fail "final artifact did not preserve complete exact-once results"
  rm -rf "$tmp"
  pass "watchdog fails hung scripts, cleans descendants, and persists partial evidence"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  "$RUNNER" --aggregate-json "$tmp/reversed.json" "$tmp/b.json" "$tmp/a.json" >/dev/null
  cmp -s "$tmp/out.json" "$tmp/reversed.json" \
    || { rm -rf "$tmp"; fail "aggregate JSON depends on input order"; }
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

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
test_parallel_signal_cleanup
test_serial_signal_cleanup
test_completed_worker_descendant_cleanup
test_environment_isolation_in_serial_and_parallel_children
test_duration_budget_warns_and_ci_enforces
test_watchdog_timeout_cleanup_and_incremental_evidence
test_aggregate_json
