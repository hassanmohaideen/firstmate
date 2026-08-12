#!/usr/bin/env bash
# Behavior tests for the disabled-by-default RTK orientation helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
HELPER="$ROOT/bin/fm-rtk.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
RAW_LOG="$TMP_ROOT/raw.json"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
LAST_RC=0
EXPECTED_SHA=17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
export RAW_LOG

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Darwin}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-arm64}" ;;
  *) exit 2 ;;
esac
SH

cat > "$FAKEBIN/shasum" <<SH
#!/usr/bin/env bash
if [ "\${FAKE_HASH_MODE:-}" = mismatch ]; then
  printf '%s  %s\n' deadbeef "\${3:-unknown}"
else
  printf '%s  %s\n' '$EXPECTED_SHA' "\${3:-unknown}"
fi
SH

cat > "$FAKEBIN/raw-tool" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "$RAW_LOG.count"
python3 - "$RAW_LOG" "${0##*/}" "$@" <<'PY'
import json, sys
path, tool, *args = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"tool": tool, "args": args}, f, ensure_ascii=False)
PY
case "${RAW_MODE:-ok}" in
  ok)
    printf 'raw stdout\n'
    printf 'raw stderr\n' >&2
    exit 0
    ;;
  fail)
    printf 'raw failure stdout\n'
    printf 'raw failure stderr\n' >&2
    exit 42
    ;;
  signal)
    printf 'raw before signal\n'
    kill -TERM "$$"
    sleep 2
    exit 99
    ;;
  *) exit 98 ;;
esac
SH

chmod +x "$FAKEBIN/uname" "$FAKEBIN/shasum" "$FAKEBIN/raw-tool"
ln -s raw-tool "$FAKEBIN/git"
ln -s raw-tool "$FAKEBIN/rg"
ln -s raw-tool "$FAKEBIN/ls"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  printf 'v0.45.0\n' > "$home/config/rtk"
  cat > "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk" <<'SH'
#!/usr/bin/env bash
self_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
mode=ok
[ ! -f "$self_dir/rtk.mode" ] || IFS= read -r mode < "$self_dir/rtk.mode"
if [ "${1:-}" = --version ]; then
  printf 'version\n' >> "$self_dir/version.calls"
  case "$mode" in
    startup-fail) exit 126 ;;
    bad-version) printf 'rtk 9.9.9\n'; exit 0 ;;
    noisy-version) printf 'rtk 0.45.0\n'; printf 'noise\n' >&2; exit 0 ;;
    *) printf 'rtk 0.45.0\n'; exit 0 ;;
  esac
fi
printf 'call\n' >> "$self_dir/invocation.calls"
python3 - "$self_dir/invocation.json" "$@" <<'PY'
import json, os, sys
path, *args = sys.argv[1:]
keys = [
    "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR",
    "RTK_DB_PATH", "RTK_TELEMETRY_DISABLED", "RTK_TEE", "RTK_NO_TOML",
    "NO_COLOR", "PAGER", "GIT_PAGER", "PATH", "RTK_TRUST_PROJECT_FILTERS",
]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"args": args, "env": {k: os.environ.get(k) for k in keys}}, f, ensure_ascii=False)
PY
case "$mode" in
  fail)
    printf 'compact failure stdout\n'
    printf 'compact failure stderr\n' >&2
    exit 23
    ;;
  empty) exit 0 ;;
  signal)
    printf 'compact before signal\n'
    kill -TERM "$$"
    sleep 2
    exit 99
    ;;
  hang)
    trap 'exit 143' TERM
    while :; do sleep 1; done
    ;;
  *)
    printf 'compact stdout\n'
    printf 'compact stderr\n' >&2
    exit 0
    ;;
esac
SH
  chmod +x "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk"
  printf '%s\n' "$home"
}

artifact_dir() {
  printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin\n' "$1"
}

run_helper() {
  local home=$1 cwd=$2
  shift 2
  rm -f "$RAW_LOG" "$RAW_LOG.count" "$OUT" "$ERR"
  (
    cd "$cwd" || exit 97
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" "$@"
  ) > "$OUT" 2> "$ERR"
  LAST_RC=$?
}

assert_json_call() {
  local path=$1 tool=$2
  shift 2
  python3 - "$path" "$tool" "$@" <<'PY' || fail "unexpected argv in $path"
import json, sys
path, expected_tool, *expected_args = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
actual_tool = value.get("tool")
actual_args = value.get("args")
if actual_tool is None:
    actual_tool = "rtk"
    actual_args = value.get("args")
if actual_tool != expected_tool or actual_args != expected_args:
    raise SystemExit(f"expected {expected_tool!r} {expected_args!r}, got {actual_tool!r} {actual_args!r}")
PY
}

assert_raw_once() {
  local tool=$1
  shift
  local count
  assert_present "$RAW_LOG" "raw fallback did not execute"
  assert_json_call "$RAW_LOG" "$tool" "$@"
  count=$(wc -l < "$RAW_LOG.count" | tr -d '[:space:]')
  [ "$count" = 1 ] || fail "raw fallback executed $count times instead of once"
}

assert_no_execution() {
  local home=$1
  assert_absent "$RAW_LOG" "refused request still executed a raw command"
  assert_absent "$RAW_LOG.count" "refused request still started a raw command"
  assert_absent "$(artifact_dir "$home")/invocation.json" "refused request still executed RTK"
  assert_absent "$(artifact_dir "$home")/version.calls" "refused request still preflighted RTK"
}

assert_tmp_cleaned_from_invocation() {
  local invocation=$1 tmp_home
  tmp_home=$(python3 - "$invocation" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["env"]["HOME"])
PY
)
  case "$tmp_home" in
    */fm-rtk.*/home) ;;
    *) fail "RTK HOME was not under an invocation-private root: $tmp_home" ;;
  esac
  assert_absent "${tmp_home%/home}" "invocation-private RTK root survived completion"
}

test_help_and_parse() {
  local help rc
  bash -n "$HELPER" || fail "fm-rtk.sh does not parse"
  help=$($HELPER --help); rc=$?
  expect_code 0 "$rc" "fm-rtk.sh --help should succeed"
  assert_contains "$help" "No arbitrary command" "help omitted the generic-command denial"
  assert_contains "$help" "never automatically reruns" "help omitted the post-start no-rerun contract"
  pass "fm-rtk: help exposes the bounded public contract"
}

test_raw_fallback_matrix() {
  local home artifact target case_name

  home="$TMP_ROOT/off-home"
  mkdir -p "$home/config"
  run_helper "$home" "$TMP_ROOT" git-log
  expect_code 0 "$LAST_RC" "default-off helper should run raw"
  assert_raw_once git log -n 50 --decorate
  assert_grep "unavailable (disabled)" "$ERR" "default-off fallback reason was not visible"

  home=$(make_home bad-pin-home)
  printf 'develop\n' > "$home/config/rtk"
  run_helper "$home" "$TMP_ROOT" git-status
  assert_raw_once git status
  assert_grep "invalid pin" "$ERR" "bad pin fallback reason was not visible"

  home=$(make_home symlink-config-home)
  target="$home/config/real-rtk"
  mv "$home/config/rtk" "$target"
  ln -s real-rtk "$home/config/rtk"
  run_helper "$home" "$TMP_ROOT" git-status
  assert_raw_once git status
  assert_absent "$(artifact_dir "$home")/version.calls" "symlink config still preflighted RTK"

  home=$(make_home unsupported-home)
  FAKE_UNAME_S=Linux run_helper "$home" "$TMP_ROOT" git-status
  assert_raw_once git status
  assert_grep "unsupported platform" "$ERR" "unsupported platform fallback reason was not visible"

  for case_name in missing directory symlink nonexec hash version noisy-version startup; do
    home=$(make_home "artifact-$case_name-home")
    artifact="$(artifact_dir "$home")/rtk"
    case "$case_name" in
      missing) rm -f "$artifact" ;;
      directory) rm -f "$artifact"; mkdir "$artifact" ;;
      symlink) mv "$artifact" "$artifact.real"; ln -s rtk.real "$artifact" ;;
      nonexec) chmod -x "$artifact" ;;
      hash) : ;;
      version) printf 'bad-version\n' > "$(artifact_dir "$home")/rtk.mode" ;;
      noisy-version) printf 'noisy-version\n' > "$(artifact_dir "$home")/rtk.mode" ;;
      startup) printf 'startup-fail\n' > "$(artifact_dir "$home")/rtk.mode" ;;
    esac
    if [ "$case_name" = hash ]; then
      FAKE_HASH_MODE=mismatch run_helper "$home" "$TMP_ROOT" git-status
    else
      run_helper "$home" "$TMP_ROOT" git-status
    fi
    assert_raw_once git status
    expect_code 0 "$LAST_RC" "$case_name setup should fall back to successful raw status"
    assert_absent "$(artifact_dir "$home")/invocation.json" "$case_name setup executed compact RTK"
    case "$case_name" in
      missing|directory|symlink|nonexec|hash)
        assert_absent "$(artifact_dir "$home")/version.calls" "$case_name artifact was executed before refusal"
        ;;
    esac
  done
  pass "fm-rtk: disabled, platform, pin, type, integrity, version, and startup failures fall back raw exactly once"
}

test_raw_fallback_preserves_streams_status_and_signal() {
  local home
  home="$TMP_ROOT/raw-behavior-home"
  mkdir -p "$home/config"

  RAW_MODE=fail run_helper "$home" "$TMP_ROOT" git-status
  expect_code 42 "$LAST_RC" "raw fallback lost the child failure status"
  assert_grep "raw failure stdout" "$OUT" "raw fallback lost stdout"
  assert_grep "raw failure stderr" "$ERR" "raw fallback lost stderr"
  assert_raw_once git status

  RAW_MODE=signal run_helper "$home" "$TMP_ROOT" git-status
  expect_code 143 "$LAST_RC" "raw fallback did not preserve TERM status"
  assert_grep "raw before signal" "$OUT" "raw fallback lost pre-signal output"
  assert_raw_once git status
  pass "fm-rtk: raw fallback preserves stdout, stderr, status, and termination"
}

test_admission_refuses_without_execution() {
  local home case_name rc
  home=$(make_home admission-home)
  mkdir -p "$TMP_ROOT/a-directory"

  while IFS='|' read -r case_name argline; do
    [ -n "$case_name" ] || continue
    rm -f "$RAW_LOG" "$RAW_LOG.count" "$(artifact_dir "$home")/invocation.json" "$(artifact_dir "$home")/version.calls"
    case "$case_name" in
      no-verb) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" > "$OUT" 2> "$ERR"; rc=$? ;;
      unknown) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" rtk proxy git status > "$OUT" 2> "$ERR"; rc=$? ;;
      lifecycle) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" fm-watch > "$OUT" 2> "$ERR"; rc=$? ;;
      structured-axi) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" tasks-axi > "$OUT" 2> "$ERR"; rc=$? ;;
      exact-parser) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" jq > "$OUT" 2> "$ERR"; rc=$? ;;
      build) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" cargo-test > "$OUT" 2> "$ERR"; rc=$? ;;
      mutation) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" git-push > "$OUT" 2> "$ERR"; rc=$? ;;
      shell-direct) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" -- sh -c 'git status' > "$OUT" 2> "$ERR"; rc=$? ;;
      log-extra) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" git-log --all > "$OUT" 2> "$ERR"; rc=$? ;;
      diff-extra) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" git-diff --stat > "$OUT" 2> "$ERR"; rc=$? ;;
      status-extra) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" git-status --porcelain > "$OUT" 2> "$ERR"; rc=$? ;;
      search-missing) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" search > "$OUT" 2> "$ERR"; rc=$? ;;
      search-option) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" search --json . > "$OUT" 2> "$ERR"; rc=$? ;;
      search-operator) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" search '|' . > "$OUT" 2> "$ERR"; rc=$? ;;
      list-option) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" list --all > "$OUT" 2> "$ERR"; rc=$? ;;
      list-extra) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" list "$TMP_ROOT/a-directory" extra > "$OUT" 2> "$ERR"; rc=$? ;;
      list-file) PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" list "$home/config/rtk" > "$OUT" 2> "$ERR"; rc=$? ;;
      *) fail "unknown admission fixture $case_name ($argline)" ;;
    esac
    expect_code 64 "$rc" "$case_name should be an admission refusal"
    assert_no_execution "$home"
  done <<'ROWS'
no-verb|
unknown|rtk proxy git status
lifecycle|fm-watch
structured-axi|tasks-axi
exact-parser|jq
build|cargo-test
mutation|git-push
shell-direct|-- sh -c git-status
log-extra|git-log --all
diff-extra|git-diff --stat
status-extra|git-status --porcelain
search-missing|search
search-option|search --json .
search-operator|search pipe
list-option|list --all
list-extra|list dir extra
list-file|list file
ROWS
  pass "fm-rtk: generic, extra, option-like, machine, operator, and non-directory requests execute nothing"
}

test_exact_compact_mappings_and_hostile_data() {
  local home invocation hostile_path hostile_pattern
  home=$(make_home mapping-home)
  invocation="$(artifact_dir "$home")/invocation.json"

  run_helper "$home" "$TMP_ROOT" git-log
  expect_code 0 "$LAST_RC" "git-log compact invocation failed"
  assert_json_call "$invocation" rtk git log -n 50 --decorate
  assert_absent "$RAW_LOG" "successful compact git-log also ran raw"

  run_helper "$home" "$TMP_ROOT" git-diff
  assert_json_call "$invocation" rtk git diff
  run_helper "$home" "$TMP_ROOT" git-diff --cached
  assert_json_call "$invocation" rtk git diff --cached
  run_helper "$home" "$TMP_ROOT" git-status
  assert_json_call "$invocation" rtk git status

  hostile_path="$TMP_ROOT/space \$() ; unicode-⚓"
  mkdir -p "$hostile_path"
  # shellcheck disable=SC2016 # Literal command-substitution bytes are hostile argv data.
  hostile_pattern='needle;$(touch SHOULD_NOT_EXIST)|⚓'
  run_helper "$home" "$TMP_ROOT" search "$hostile_pattern" "$hostile_path"
  assert_json_call "$invocation" rtk rg "$hostile_pattern" "$hostile_path"
  assert_absent "$TMP_ROOT/SHOULD_NOT_EXIST" "search data was evaluated as shell syntax"
  assert_no_grep "$hostile_pattern" "$ERR" "helper observability leaked the search pattern"

  run_helper "$home" "$TMP_ROOT" list "$hostile_path"
  assert_json_call "$invocation" rtk ls "$hostile_path"
  assert_absent "$TMP_ROOT/SHOULD_NOT_EXIST" "list path was evaluated as shell syntax"
  pass "fm-rtk: every semantic verb maps exact argv and hostile metacharacters remain data"
}

test_privacy_environment_and_cleanup() {
  local home invocation
  home=$(make_home privacy-home)
  invocation="$(artifact_dir "$home")/invocation.json"

  RTK_DB_PATH=/unsafe/history \
  RTK_TELEMETRY_DISABLED=0 \
  RTK_TEE=1 \
  RTK_NO_TOML=0 \
  RTK_TRUST_PROJECT_FILTERS=1 \
  HOME=/unsafe/home \
  XDG_CONFIG_HOME=/unsafe/config \
  XDG_DATA_HOME=/unsafe/data \
  XDG_CACHE_HOME=/unsafe/cache \
  NO_COLOR=0 PAGER=less GIT_PAGER=less \
    run_helper "$home" "$TMP_ROOT" git-status
  expect_code 0 "$LAST_RC" "privacy fixture compact invocation failed"
  python3 - "$invocation" <<'PY' || fail "forced RTK privacy environment was incomplete or overrideable"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    env = json.load(f)["env"]
for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR", "RTK_DB_PATH"):
    if "/fm-rtk." not in env[key]:
        raise SystemExit(f"{key} is not invocation-private: {env[key]!r}")
expected = {
    "RTK_TELEMETRY_DISABLED": "1",
    "RTK_TEE": "0",
    "RTK_NO_TOML": "1",
    "NO_COLOR": "1",
    "PAGER": "cat",
    "GIT_PAGER": "cat",
    "RTK_TRUST_PROJECT_FILTERS": None,
}
for key, value in expected.items():
    if env.get(key) != value:
        raise SystemExit(f"{key}: expected {value!r}, got {env.get(key)!r}")
PY
  assert_tmp_cleaned_from_invocation "$invocation"
  assert_absent "$home/data/history.db" "RTK history escaped into the operational home"
  assert_grep "using RTK v0.45.0 for supplemental git-status orientation" "$ERR" \
    "compact observability line omitted its fixed class and pin"
  assert_no_grep "$home" "$ERR" "compact observability leaked an operational path"
  pass "fm-rtk: forced privacy settings override caller values and temporary state is removed"
}

test_no_raw_rerun_after_rtk_starts() {
  local home mode invocation count
  home=$(make_home no-rerun-home)
  invocation="$(artifact_dir "$home")/invocation.json"

  for mode in fail empty signal; do
    printf '%s\n' "$mode" > "$(artifact_dir "$home")/rtk.mode"
    run_helper "$home" "$TMP_ROOT" git-status
    case "$mode" in
      fail)
        expect_code 23 "$LAST_RC" "compact failure status was not preserved"
        assert_grep "compact failure stdout" "$OUT" "compact failure lost stdout"
        assert_grep "compact failure stderr" "$ERR" "compact failure lost stderr"
        ;;
      empty) expect_code 0 "$LAST_RC" "empty compact success changed status" ;;
      signal) expect_code 143 "$LAST_RC" "compact signal status was not preserved" ;;
    esac
    assert_absent "$RAW_LOG" "$mode compact outcome incorrectly reran raw"
    assert_present "$invocation" "$mode compact outcome never started RTK"
    count=$(wc -l < "$(artifact_dir "$home")/invocation.calls" | tr -d '[:space:]')
    [ "$count" = 1 ] || fail "$mode compact outcome invoked RTK $count times"
    rm -f "$(artifact_dir "$home")/invocation.calls"
    assert_tmp_cleaned_from_invocation "$invocation"
  done
  pass "fm-rtk: failure, empty, and signalled compact outcomes never trigger a raw rerun"
}

test_caught_termination_cleans_private_state() {
  local home invocation helper_pid tmp_home rc=0 i=0
  home=$(make_home caught-term-home)
  invocation="$(artifact_dir "$home")/invocation.json"
  printf 'hang\n' > "$(artifact_dir "$home")/rtk.mode"
  rm -f "$RAW_LOG" "$RAW_LOG.count" "$OUT" "$ERR" "$invocation"
  (
    cd "$TMP_ROOT" || exit 97
    exec env PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$HELPER" git-status
  ) > "$OUT" 2> "$ERR" &
  helper_pid=$!
  while [ ! -f "$invocation" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_present "$invocation" "termination fixture never started compact RTK"
  tmp_home=$(python3 - "$invocation" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["env"]["HOME"])
PY
)
  kill -TERM "$helper_pid"
  wait "$helper_pid" || rc=$?
  expect_code 143 "$rc" "caught TERM did not preserve termination status"
  assert_absent "${tmp_home%/home}" "caught TERM left the private RTK root behind"
  assert_absent "$RAW_LOG" "caught TERM triggered a raw rerun"
  pass "fm-rtk: caught termination forwards, cleans private state, and never reruns raw"
}

test_help_and_parse
test_raw_fallback_matrix
test_raw_fallback_preserves_streams_status_and_signal
test_admission_refuses_without_execution
test_exact_compact_mappings_and_hostile_data
test_privacy_environment_and_cleanup
test_no_raw_rerun_after_rtk_starts
test_caught_termination_cleans_private_state
