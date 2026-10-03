#!/usr/bin/env bash
# Behavior tests for fm-jev.sh - the optional TypeSafe Jev dispatch second opinion.
#
# The contract this suite pins:
#   - advisory-only and fail-open: a missing or unsafe key, a refused endpoint, a
#     connection failure, a timeout, an HTTP error, a malformed response, or an
#     unexpected answering model each print one JEV_UNAVAILABLE line and exit 0;
#   - the key is never printed, logged, or passed on curl's argv;
#   - the audit log records the recommendation, confidence, and latency but never
#     the key or the task text;
#   - report compares the latest advice with the recorded decision per task;
#   - only the fixed advisory subcommands exist.
#
# Every HTTP call goes to a local stub server on 127.0.0.1; no test reaches the
# live TypeSafe API.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-jev.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-tests)
PYTHON_BIN=$(command -v python3 2>/dev/null || true)
REAL_CURL=$(command -v curl 2>/dev/null || true)
[ -n "$PYTHON_BIN" ] || fail "python3 is required for the stub TypeSafe endpoint"
[ -n "$REAL_CURL" ] || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

SECRET_KEY='tsk-SENTINEL-KEY-0123456789abcdef'

# --- stub TypeSafe endpoint ----------------------------------------------------

STUB_DIR="$TMP_ROOT/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/server.py" <<'PY'
import http.server, json, sys, time
port_file, mode_file, log = sys.argv[1], sys.argv[2], sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def _mode(self):
        try:
            return open(mode_file).read().strip()
        except OSError:
            return 'ok'

    def _record(self, body):
        with open(log, 'a') as f:
            f.write(json.dumps({'method': self.command, 'path': self.path,
                                'auth': self.headers.get('Authorization', ''),
                                'body': body}) + '\n')

    def _common(self):
        mode = self._mode()
        if mode == 'timeout':
            time.sleep(30)
        if mode == '401':
            self._reply(401, '{"error":"bad key"}')
            return None
        if mode == '529':
            self._reply(529, '{"error":"overloaded"}')
            return None
        return mode

    def do_GET(self):
        self._record(None)
        if self._common() is None:
            return
        self._reply(200, json.dumps({'data': [{'id': 'jev-latest'}, {'id': 'jev-preview'}]}))

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        self._record(req)
        mode = self._common()
        if mode is None:
            return
        if mode == 'malformed':
            return self._reply(200, '{"model": "jev-1.13.0", "answers": ')
        if mode == 'wrongmodel':
            return self._reply(200, json.dumps({'model': 'jev-9.9.9', 'answers': {}, 'usage': {}}))
        answers = {'ambiguity': {'type': 'score', 'score': 1.2, 'legend': {}, 'probabilities': {},
                                 'confidence': 0.66}}
        questions = req['questions']
        if 'tier' in questions:
            options = list(questions['tier']['criteria'].keys())
            pick = open(mode_file + '.pick').read().strip() if mode == 'pick' else options[1]
            probs = {o: (0.8 if o == pick else round(0.2 / (len(options) - 1), 4)) for o in options}
            answers['tier'] = {'type': 'choice', 'choice': pick, 'probabilities': probs, 'confidence': 0.74}
            for key in questions:
                if key.startswith('fits:'):
                    answers[key] = {'type': 'noul', 'noul': 0.9 if key == 'fits:' + pick else 0.1}
        self._reply(200, json.dumps({'model': req['model'], 'answers': answers,
                                     'usage': {'input_tokens': 1234, 'output_tokens': 20}}))

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
with open(port_file + '.tmp', 'w') as f:
    f.write(str(server.server_address[1]))
import os
os.rename(port_file + '.tmp', port_file)
server.serve_forever()
PY

STUB_MODE="$STUB_DIR/mode"
STUB_LOG="$STUB_DIR/requests.jsonl"
"$PYTHON_BIN" "$STUB_DIR/server.py" "$STUB_DIR/port" "$STUB_MODE" "$STUB_LOG" &
STUB_PID=$!
stop_stub() { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }
trap 'stop_stub; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do
  [ -s "$STUB_DIR/port" ] && break
  sleep 0.05
done
[ -s "$STUB_DIR/port" ] || fail "stub TypeSafe endpoint did not start"
STUB_URL="http://127.0.0.1:$(cat "$STUB_DIR/port")"

# A curl shim that records its argv, then runs the real curl unchanged.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/curl-argv.log"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$FAKEBIN/curl"

# --- fixtures ----------------------------------------------------------------

TASK_TEXT='Fix a typo in the README install section. TASK-TEXT-SENTINEL-must-not-be-logged.'

new_home() {
  local home="$TMP_ROOT/home-$1"
  mkdir -p "$home/config" "$home/state"
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{
  "rules": [
    { "when": "Easy, well-understood mechanical edits or documentation changes.",
      "use": { "harness": "claude", "model": "sonnet", "effort": "low" } },
    { "when": "Medium-complexity implementation with an accepted design.",
      "use": { "harness": "claude", "model": "opus", "effort": "medium" } },
    { "when": "Genuinely unresolved architecture or design.",
      "use": [ { "harness": "claude", "model": "opus" }, { "harness": "codex" } ] }
  ],
  "default": { "harness": "claude" }
}
JSON
  cat > "$home/tracked-dispatch.json" <<'JSON'
{ "rules": [ { "when": "A Playop review task.", "use": { "harness": "claude", "model": "opus" } } ] }
JSON
  printf 'Task-%s: %s\n' "$1" "$TASK_TEXT" > "$home/task.md"
  printf '%s\n' "$home"
}

write_key() {
  local home=$1 mode=${2:-600}
  printf '# TypeSafe key\nTYPESAFE_API_KEY=%s\n' "$SECRET_KEY" > "$home/config/typesafe.env"
  chmod "$mode" "$home/config/typesafe.env"
}

# run_jev <home> <args...>: runs with the stub endpoint; sets OUT and RC.
run_jev() {
  local home=$1
  shift
  OUT=$(env -u TYPESAFE_API_KEY -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$FAKEBIN:$PATH" FM_HOME="$home" \
    FM_TEST_DISPATCH_DEFAULTS_PATH="$home/tracked-dispatch.json" \
    FM_JEV_BASE_URL="${JEV_BASE_URL:-$STUB_URL}" FM_JEV_TIMEOUT="${JEV_TIMEOUT:-3}" \
    ${JEV_ENV_KEY:+TYPESAFE_API_KEY="$JEV_ENV_KEY"} \
    "$SCRIPT" "$@" 2>&1)
  RC=$?
  assert_not_contains "$OUT" "$SECRET_KEY" "output must never contain the key"
}

set_mode() { printf '%s\n' "$1" > "$STUB_MODE"; }
request_count() { if [ -f "$STUB_LOG" ]; then wc -l < "$STUB_LOG" | tr -d ' '; else echo 0; fi; }

# --- tests ---------------------------------------------------------------------

test_status_without_key_is_disabled_and_offline() {
  local home before
  home=$(new_home status)
  before=$(request_count)
  run_jev "$home" status
  expect_code 0 "$RC" "status without key"
  assert_contains "$OUT" "jev=disabled key=absent" "status reports the absent key"
  [ "$(request_count)" = "$before" ] || fail "status must not touch the network"
  write_key "$home"
  run_jev "$home" status
  assert_contains "$OUT" "jev=configured key=present key_source=file model=jev-1.13.0" "status reports a configured key"
  pass "status reports key presence without network access or the key"
}

test_missing_key_fails_open() {
  local home before
  home=$(new_home nokey)
  before=$(request_count)
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-nokey
  expect_code 0 "$RC" "dispatch-tier without key"
  assert_contains "$OUT" "JEV_UNAVAILABLE: no key configured" "missing key prints an unavailable line"
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "unavailable output must be exactly one line"
  [ "$(request_count)" = "$before" ] || fail "missing key must not touch the network"
  jq -e 'select(.task_id == "t-nokey") | .outcome == "unavailable"' "$home/state/jev-advice.jsonl" >/dev/null \
    || fail "unavailable call is logged"
  pass "missing key prints JEV_UNAVAILABLE, exits 0, and stays offline"
}

test_loose_key_file_is_not_read() {
  local home before
  home=$(new_home loose)
  write_key "$home" 644
  before=$(request_count)
  run_jev "$home" dispatch-tier --task-file "$home/task.md"
  expect_code 0 "$RC" "loose key file"
  assert_contains "$OUT" "JEV_UNAVAILABLE: config/typesafe.env must be a regular, single-linked, mode-0600 file" "loose key file refused"
  [ "$(request_count)" = "$before" ] || fail "a loose key file must not be used"
  pass "a non-0600 key file is refused without reading the key"
}

test_dispatch_tier_success() {
  local home req
  home=$(new_home ok)
  write_key "$home"
  set_mode ok
  : > "$TMP_ROOT/curl-argv.log"
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-ok
  expect_code 0 "$RC" "dispatch-tier success"
  assert_contains "$OUT" "jev=ok mode=dispatch-tier task_id=t-ok model=jev-1.13.0" "success header"
  assert_contains "$OUT" "recommended_tier=local-2 tier_confidence=0.74 recommended_effort=medium effort_source=rule profiles=single" "recommendation line"
  assert_contains "$OUT" "tier local-1 choice_p=0.05 fits_p=0.1" "per-rule probabilities"
  assert_contains "$OUT" "tier tracked-1 " "tracked rules are ranked"
  assert_contains "$OUT" "tier none choice_p=" "the no-rule option is reported"
  assert_contains "$OUT" "ambiguity score=1.2 confidence=0.66 fallback_effort=medium" "ambiguity line"
  assert_contains "$OUT" "advisory=data-only" "advisory marker"

  req=$(tail -n 1 "$STUB_LOG")
  [ "$(printf '%s' "$req" | jq -r '.auth')" = "Bearer $SECRET_KEY" ] || fail "the key is sent as a bearer header"
  [ "$(printf '%s' "$req" | jq -r '.body.model')" = jev-1.13.0 ] || fail "the model is pinned"
  printf '%s' "$req" | jq -e '.body.state.task | contains("TASK-TEXT-SENTINEL")' >/dev/null || fail "task text is the state"
  printf '%s' "$req" | jq -e '.body.questions.tier.criteria | keys == ["local-1","local-2","local-3","none","tracked-1"]' >/dev/null \
    || fail "every effective rule plus none is an option"
  assert_no_grep "$SECRET_KEY" "$TMP_ROOT/curl-argv.log" "the key never appears on curl argv"
  assert_grep "-H @-" "$TMP_ROOT/curl-argv.log" "the header is read from stdin"
  pass "dispatch-tier returns a recommendation with confidence and keeps the key off argv"
}

test_array_rule_and_ambiguity_effort() {
  local home
  home=$(new_home array)
  write_key "$home"
  set_mode pick
  printf 'local-3\n' > "$STUB_MODE.pick"
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-array
  expect_code 0 "$RC" "array rule"
  assert_contains "$OUT" "recommended_tier=local-3 tier_confidence=0.74 recommended_effort=medium effort_source=ambiguity profiles=array" "array rule effort comes from ambiguity"
  set_mode ok
  pass "a profile-array rule is flagged and its effort comes from the ambiguity advisory"
}

test_effort_advisory() {
  local home req
  home=$(new_home effort)
  write_key "$home"
  set_mode ok
  run_jev "$home" effort --task-file - --task-id t-effort < "$home/task.md"
  expect_code 0 "$RC" "effort advisory"
  assert_contains "$OUT" "jev=ok mode=effort task_id=t-effort" "effort header"
  assert_contains "$OUT" "fallback_effort=medium" "effort mapping"
  assert_not_contains "$OUT" "recommended_tier" "effort mode ranks no tiers"
  req=$(tail -n 1 "$STUB_LOG")
  printf '%s' "$req" | jq -e '.body.questions | keys == ["ambiguity"]' >/dev/null || fail "effort sends only the ambiguity question"
  pass "effort rates ambiguity only and maps it to a fallback effort"
}

test_env_key_override() {
  local home
  home=$(new_home envkey)
  JEV_ENV_KEY="$SECRET_KEY" run_jev "$home" status
  assert_contains "$OUT" "key_source=env" "env key wins"
  set_mode ok
  JEV_ENV_KEY="$SECRET_KEY" run_jev "$home" effort --task-file "$home/task.md"
  assert_contains "$OUT" "jev=ok" "env key is usable"
  pass "TYPESAFE_API_KEY overrides the key file"
}

test_failure_modes_fail_open() {
  local home start elapsed
  home=$(new_home fail)
  write_key "$home"

  set_mode timeout
  start=$(date +%s)
  JEV_TIMEOUT=1 run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-timeout
  elapsed=$(($(date +%s) - start))
  expect_code 0 "$RC" "timeout"
  assert_contains "$OUT" "JEV_UNAVAILABLE: timeout after 1s" "timeout is reported"
  # The stub stalls 30s; a generous bound proves the 1s timeout without
  # flaking when the host is loaded.
  [ "$elapsed" -le 15 ] || fail "timeout must be bounded (took ${elapsed}s)"

  set_mode malformed
  run_jev "$home" dispatch-tier --task-file "$home/task.md"
  expect_code 0 "$RC" "malformed"
  assert_contains "$OUT" "JEV_UNAVAILABLE: malformed or unexpected response" "malformed body"

  set_mode wrongmodel
  run_jev "$home" effort --task-file "$home/task.md"
  assert_contains "$OUT" "JEV_UNAVAILABLE: malformed or unexpected response" "unexpected model"

  set_mode 401
  run_jev "$home" dispatch-tier --task-file "$home/task.md"
  assert_contains "$OUT" "JEV_UNAVAILABLE: HTTP 401 (key rejected)" "401"

  set_mode 529
  run_jev "$home" dispatch-tier --task-file "$home/task.md"
  assert_contains "$OUT" "JEV_UNAVAILABLE: HTTP 529 (overloaded)" "529"
  set_mode ok

  JEV_BASE_URL="http://127.0.0.1:1" run_jev "$home" dispatch-tier --task-file "$home/task.md"
  expect_code 0 "$RC" "connection refused"
  assert_contains "$OUT" "JEV_UNAVAILABLE: network error" "connection failure"

  JEV_BASE_URL="http://example.invalid" run_jev "$home" dispatch-tier --task-file "$home/task.md"
  assert_contains "$OUT" "JEV_UNAVAILABLE: refusing non-https API base URL" "plain http to a remote host is refused"
  pass "timeout, malformed, wrong model, HTTP errors, and network failure all fail open"
}

test_probe() {
  local home
  home=$(new_home probe)
  run_jev "$home" probe
  expect_code 0 "$RC" "probe without key"
  assert_contains "$OUT" "JEV_UNAVAILABLE: no key configured" "probe without key"
  write_key "$home"
  set_mode ok
  run_jev "$home" probe
  assert_contains "$OUT" "jev=reachable http=200" "probe reachable"
  assert_contains "$OUT" "listed_models=jev-latest,jev-preview" "probe lists models"
  [ "$(tail -n 1 "$STUB_LOG" | jq -r '.method + " " + .path')" = "GET /v1/models" ] || fail "probe calls GET /v1/models"
  set_mode 401
  run_jev "$home" probe
  assert_contains "$OUT" "JEV_UNAVAILABLE: HTTP 401" "probe reports a rejected key"
  set_mode ok
  pass "probe checks key presence and reachability"
}

test_log_format_and_report() {
  local home log
  home=$(new_home report)
  write_key "$home"
  set_mode ok
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-agree
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-disagree
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-pending
  run_jev "$home" record --task-id t-agree --tier local-2 --effort medium --followed yes
  assert_contains "$OUT" "recorded task_id=t-agree chosen_tier=local-2" "record confirms"
  run_jev "$home" record --task-id t-disagree --tier local-3 --effort xhigh --followed no --reason "design is still open"
  set_mode 529
  run_jev "$home" dispatch-tier --task-file "$home/task.md" --task-id t-down
  set_mode ok

  log="$home/state/jev-advice.jsonl"
  assert_present "$log" "the audit log exists"
  [ "$(if [ "$(uname)" = Darwin ]; then stat -f %Lp "$log"; else stat -c %a "$log"; fi)" = 600 ] || fail "the audit log is mode 0600"
  assert_no_grep "$SECRET_KEY" "$log" "the log never contains the key"
  assert_no_grep "TASK-TEXT-SENTINEL" "$log" "the log never contains the task text"
  jq -e 'select(.task_id == "t-agree" and .kind == "advice")
    | (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and .outcome == "ok" and .mode == "dispatch-tier"
      and .recommended_tier == "local-2" and .tier_confidence == 0.74 and .recommended_effort == "medium"
      and (.latency_ms | type) == "number" and .model == "jev-1.13.0" and (.task_sha256 | length) == 64
      and .tier_probabilities["local-2"] == 0.8' "$log" >/dev/null || fail "advice record fields"
  jq -e 'select(.kind == "decision" and .task_id == "t-disagree")
    | .chosen_tier == "local-3" and .followed == "no" and .reason == "design is still open"' "$log" >/dev/null \
    || fail "decision record fields"

  run_jev "$home" report
  expect_code 0 "$RC" "report"
  assert_contains "$OUT" "jev_report advice_calls=4 ok=3 unavailable=1 decisions=2" "report totals"
  assert_contains "$OUT" "comparisons=2 tier_agree=1 tier_disagree=1 effort_agree=1 effort_disagree=1" "report agreement"
  assert_contains "$OUT" "followed yes=1 partial=0 no=1" "report followed counts"
  assert_contains "$OUT" "tier_agreement high_confidence(>=0.7)=1/2" "report confidence buckets"
  assert_contains "$OUT" "advice_without_decision=1" "report unreconciled advice"
  assert_contains "$OUT" 'unavailable_reason count=1 reason="HTTP 529 (overloaded)"' "report unavailable reasons"
  assert_contains "$OUT" "disagreement task_id=t-disagree jev=local-2/medium@0.74 chosen=local-3/xhigh followed=no" "report lists disagreements"
  pass "the audit log carries the advice and decision fields and report compares them"
}

test_log_rotation() {
  local home
  home=$(new_home rotate)
  write_key "$home"
  set_mode ok
  run_jev "$home" record --task-id t-a --tier none --effort low --followed yes
  FM_JEV_LOG_MAX_BYTES=1 run_jev "$home" record --task-id t-b --tier none --effort low --followed yes
  assert_present "$home/state/jev-advice.jsonl.1" "the log rotates past its size cap"
  run_jev "$home" report
  assert_contains "$OUT" "decisions=2" "report reads the rotated generation too"
  pass "the audit log rotates once and report reads both generations"
}

test_usage_and_fixed_surface() {
  local home sub
  home=$(new_home usage)
  for sub in gate merge review ask-user quota; do
    run_jev "$home" "$sub"
    expect_code 2 "$RC" "unknown subcommand $sub"
  done
  run_jev "$home" dispatch-tier
  expect_code 2 "$RC" "dispatch-tier without task file"
  run_jev "$home" record --task-id t --tier local-1 --effort low --followed maybe
  expect_code 2 "$RC" "invalid followed value"
  run_jev "$home" --help
  expect_code 0 "$RC" "help"
  assert_contains "$OUT" "Hard exclusions" "help states the exclusions"
  pass "only the fixed advisory subcommands exist"
}

test_status_without_key_is_disabled_and_offline
test_missing_key_fails_open
test_loose_key_file_is_not_read
test_dispatch_tier_success
test_array_rule_and_ambiguity_effort
test_effort_advisory
test_env_key_override
test_failure_modes_fail_open
test_probe
test_log_format_and_report
test_log_rotation
test_usage_and_fixed_surface
