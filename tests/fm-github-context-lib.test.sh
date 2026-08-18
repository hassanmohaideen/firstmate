#!/usr/bin/env bash
# bin/fm-github-context-lib.sh is the single owner of the GitHub launch-verification
# decision. These tests pin its contract through the public functions:
#   - scope and capability come from immutable task identity;
#   - the pre-dispatch requirement decision is conditional on real GitHub need
#     and fails closed when a dispatch cannot be classified as non-GitHub work;
#   - intake resolves an authoritative selection or refuses to infer one;
#   - the gate keys on an affirmative verified-destination tuple, so a changed,
#     ambiguous, malformed, or missing destination blocks and a dropped verified
#     record can only re-probe (fail-closed), never bypass;
#   - the verified tuple is written only by a successful probe of the selected
#     destination, and even a matching tuple is re-probed under the current
#     account before launch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-github-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-github-context-lib)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# A project whose origin is an HTTPS GitHub remote. Echoes the project dir.
make_project() {  # <name> <remote-url>
  local dir="$TMP_ROOT/$1-$RANDOM"
  git init -q "$dir"
  git -C "$dir" remote add origin "$2"
  printf '%s\n' "$dir"
}

# A fake gh on PATH. Behaviour is read from a per-project config file
# (<dir>/fakebin/conf, sourced) so it is deterministic and free of env
# propagation. Keys: active (non-empty advertises --active), auth
# (ok|notlogged|network), push (true|false|notfound), org (ok|notfound). Every
# call is logged to $GH_LOG so a test can assert the probe was or was not run.
install_fake_gh() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  set_fake_gh "$1" active=1 auth=ok push=true org=ok
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
active=; auth=ok; push=true; org=ok
# shellcheck disable=SC1091
[ -f "$(dirname "$0")/conf" ] && . "$(dirname "$0")/conf"
case "$*" in
  *"auth status --help"*)
    [ -n "$active" ] && printf '  --active, --hostname\n'
    exit 0 ;;
  *"auth status"*)
    case "$auth" in
      ok) exit 0 ;;
      network) printf 'error connecting: could not resolve host\n' >&2; exit 1 ;;
      *) printf 'You are not logged into any GitHub hosts.\n' >&2; exit 1 ;;
    esac ;;
  *"user/memberships/orgs/"*)
    case "$org" in
      ok) exit 0 ;;
      *) printf 'HTTP 404: Not Found\n' >&2; exit 1 ;;
    esac ;;
  *"repos/"*)
    case "$push" in
      true) printf 'true\n'; exit 0 ;;
      false) printf 'false\n'; exit 0 ;;
      notfound) printf 'HTTP 404: Not Found\n' >&2; exit 1 ;;
      *) printf 'true\n'; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/gh"
}

# Configure the fake gh for a project. Keys: active, auth, push, org.
set_fake_gh() {  # <dir> <key=val>...
  local fb="$1/fakebin"; shift
  mkdir -p "$fb"
  : > "$fb/conf"
  printf '%s\n' "$@" >> "$fb/conf"
}

# --- scope and capability ---------------------------------------------------

test_scope_comes_from_immutable_task_identity() {
  fm_github_ctx_scope ship no-mistakes || fail "a no-mistakes ship push must be gated"
  fm_github_ctx_scope ship direct-PR || fail "a direct-PR ship push must be gated"
  ! fm_github_ctx_scope ship local-only || fail "a local-only ship must not be gated"
  ! fm_github_ctx_scope scout '' '' || fail "a scout with no authentication requirement is not gated"
  fm_github_ctx_scope scout '' 1 || fail "an authentication scout is gated"
  ! fm_github_ctx_scope secondmate '' '' || fail "a secondmate is never gated"
  # a ship with an unknown/empty mode fails closed into scope
  fm_github_ctx_scope ship '' || fail "a ship with an unresolved mode must fail closed into scope"
  pass "scope is derived from immutable kind/mode and the recorded scout requirement"
}

test_dispatch_requires_auth_is_conditional_and_fails_closed() {
  # A GitHub-needing task is still gated on good GitHub auth.
  fm_github_dispatch_requires_auth ship no-mistakes || fail "a no-mistakes ship push still requires GitHub auth"
  fm_github_dispatch_requires_auth ship direct-PR || fail "a direct-PR ship push still requires GitHub auth"
  fm_github_dispatch_requires_auth scout '' 1 || fail "an authenticated GitHub read scout still requires GitHub auth"
  # Non-GitHub work is NOT gated: it must dispatch even while signed out.
  ! fm_github_dispatch_requires_auth ship local-only || fail "a local-only ship must not require GitHub auth"
  ! fm_github_dispatch_requires_auth scout '' '' || fail "a plain scout with no authentication requirement must not require GitHub auth"
  ! fm_github_dispatch_requires_auth scout '' 0 || fail "a scout whose recorded requirement is 0 must not require GitHub auth"
  # An uncertain dispatch is treated as GitHub-needing (fail-closed).
  fm_github_dispatch_requires_auth ship '' || fail "a ship with an unresolved mode must fail closed and require GitHub auth"
  fm_github_dispatch_requires_auth '' '' || fail "a dispatch with no resolvable kind must fail closed and require GitHub auth"
  fm_github_dispatch_requires_auth mystery '' || fail "a dispatch of an unclassifiable kind must fail closed and require GitHub auth"
  pass "the pre-dispatch GitHub-auth requirement is conditional on real GitHub need and fails closed when uncertain"
}

test_capability_maps_kind_and_requirement() {
  [ "$(fm_github_ctx_capability ship)" = push ] || fail "a ship maps to push"
  [ "$(fm_github_ctx_capability scout private-repository-read)" = fetch ] || fail "a private-read scout maps to fetch"
  [ "$(fm_github_ctx_capability scout organization-membership-read)" = api-org-membership ] || fail "an org scout maps to api-org-membership"
  ! fm_github_ctx_capability scout bogus 2>/dev/null || fail "an unknown scout capability is refused"
  pass "the probe capability is derived from kind and the authentication requirement"
}

test_recorded_context_state_distinguishes_absent_partial_and_complete_records() {
  [ "$(fm_github_ctx_recorded_state ship '' '' '' '' '' '' '' '')" = none ] || fail "an empty context must be absent"
  [ "$(fm_github_ctx_recorded_state ship github '' repository owner/repo '' '' '' verified)" = partial ] || fail "a context missing its selected host must be partial"
  [ "$(fm_github_ctx_recorded_state ship github github.com repository owner/repo '' '' '' '')" = complete ] || fail "a ship repository context with its required fields must be complete"
  [ "$(fm_github_ctx_recorded_state scout github github.com organization '' acme 1 organization-membership-read '')" = complete ] || fail "an organization scout context with its required fields must be complete"
  [ "$(fm_github_ctx_recorded_state scout github github.com repository owner/repo '' '' private-repository-read verified)" = partial ] || fail "a scout context missing its authentication requirement must be partial"
  [ "$(fm_github_ctx_recorded_state scout github github.com organization '' '' 1 organization-membership-read verified)" = partial ] || fail "an organization context missing its organization must be partial"
  [ "$(fm_github_ctx_lifecycle_state 0 '' ship no-mistakes '' '' '' '' '' '' '' '')" = legacy ] || fail "a record with no classification or context must use legacy migration"
  [ "$(fm_github_ctx_lifecycle_state 0 '' ship no-mistakes github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a context missing only its classification marker must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 0 ship no-mistakes '' '' '' '' '' '' '' '')" = ungated ] || fail "an empty explicitly ungated context must re-derive"
  [ "$(fm_github_ctx_lifecycle_state 1 1 ship no-mistakes github github.com repository owner/repo '' '' '' verified)" = gated ] || fail "a complete explicitly gated context must remain gated"
  [ "$(fm_github_ctx_lifecycle_state 1 1 ship no-mistakes '' '' '' '' '' '' '' '')" = invalid ] || fail "an erased explicitly gated context must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 0 ship no-mistakes github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "an ungated marker with a recorded selection must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 1 ship local-only github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a gated ship whose immutable mode became local-only must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 1 ship '' github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a gated ship whose immutable mode is missing must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 1 ship arbitrary github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a gated ship whose immutable mode is unknown must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 1 '' no-mistakes github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a gated ship whose immutable kind is missing must be invalid"
  [ "$(fm_github_ctx_lifecycle_state 1 1 secondmate secondmate github github.com repository owner/repo '' '' '' verified)" = invalid ] || fail "a gated task whose immutable kind became secondmate must be invalid"
  pass "recorded context state distinguishes legacy, ungated, invalid, and complete records"
}

test_dest_tuple_is_a_stable_delimited_join() {
  [ "$(fm_github_ctx_dest_tuple github github.com repository owner/repo push)" = 'github|github.com|repository|owner/repo|push' ] \
    || fail "the destination tuple must be a stable delimited join"
  pass "the verified-destination tuple is a stable delimited join of the destination fields"
}

# --- intake -----------------------------------------------------------------

test_intake_auto_selects_github_com_but_never_infers_another_host() {
  local proj out
  proj=$(make_project autocom https://github.com/owner/repo.git)
  out=$(fm_github_ctx_intake "$proj" push '' '') || fail "github.com must auto-select without an assertion"
  [ "$out" = "$(printf 'github.com\trepository\towner/repo')" ] || fail "github.com auto-select must resolve the exact repository, got '$out'"

  proj=$(make_project enterprise https://github.enterprise.example/owner/repo.git)
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1
  [ "$?" -eq 3 ] || fail "an Enterprise host must not be inferred without --github-host (expected rc 3)"

  out=$(fm_github_ctx_intake "$proj" push github.enterprise.example '') || fail "an asserted Enterprise host that matches the remote must resolve"
  [ "$out" = "$(printf 'github.enterprise.example\trepository\towner/repo')" ] || fail "asserted Enterprise selection must resolve the repository"
  pass "intake auto-selects github.com and requires an assertion for any other host"
}

test_intake_blocks_a_missing_destination_but_leaves_local_origins_ungated() {
  local proj local_origin out rc
  proj="$TMP_ROOT/missing-origin-$RANDOM"
  git init -q "$proj"

  out=$(fm_github_ctx_intake "$proj" push '' '' 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a project with no origin must be indeterminate (expected rc 2), got $rc"
  case "$out" in
    *"GH_AUTH_INDETERMINATE: the selected project has no configured destination"*) ;;
    *) fail "a missing origin must emit an authentication-context diagnostic, got '$out'" ;;
  esac

  local_origin="$TMP_ROOT/local-origin-$RANDOM.git"
  git init -q --bare "$local_origin"
  git -C "$proj" remote add origin "$local_origin"
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "a local filesystem origin must remain ungated (expected rc 3), got $rc"
  pass "intake blocks a missing destination while leaving a local origin ungated"
}

test_intake_refuses_mismatch_and_ambiguity() {
  local proj rc
  proj=$(make_project mismatch https://github.com/owner/repo.git)
  fm_github_ctx_intake "$proj" push github.enterprise.example '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "an asserted host that does not match the remote is a hard error (expected rc 1), got $rc"

  proj=$(make_project malformed https://github.com/owner/repo.git)
  fm_github_ctx_intake "$proj" push 'Bad_Host' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "a malformed --github-host is refused (expected rc 1), got $rc"

  # two push destinations including github.com cannot establish one target
  proj=$(make_project mixed https://github.com/owner/repo.git)
  git -C "$proj" remote set-url --add --push origin https://github.com/owner/repo.git
  git -C "$proj" remote set-url --add --push origin https://github.enterprise.example/owner/repo.git
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "mixed destinations including github.com are indeterminate (expected rc 2), got $rc"

  proj=$(make_project mixednongithub https://gitlab.example/owner/repo.git)
  git -C "$proj" remote set-url --add --push origin https://github.enterprise.example/owner/repo.git
  git -C "$proj" remote set-url --add --push origin https://gitlab.example/owner/repo.git
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "multiple destinations without github.com are indeterminate (expected rc 2), got $rc"
  pass "intake refuses an asserted mismatch, a malformed host, and all multiple destinations"
}

test_intake_blocks_unrecognized_remote_transports() {
  local proj rc local_path
  proj=$(make_project remotehelper 'custom::github.com')
  fm_github_ctx_intake "$proj" push '' '' 'fm/remotehelper' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a remote-helper destination must be indeterminate (expected rc 2), got $rc"

  proj=$(make_project unknownscheme 'custom://github.com/owner/repo.git')
  fm_github_ctx_intake "$proj" push '' '' 'fm/unknownscheme' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown remote scheme must be indeterminate (expected rc 2), got $rc"

  local_path="relative/repository.git"
  proj=$(make_project relativepath "$local_path")
  fm_github_ctx_intake "$proj" push '' '' 'fm/relativepath' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "a relative filesystem destination must remain ungated (expected rc 3), got $rc"
  pass "intake blocks remote helpers and unknown schemes while recognizing filesystem destinations"
}

test_intake_rejects_unverifiable_http_transports() {
  local proj rc out
  proj=$(make_project plainhttp http://github.com/owner/repo.git)
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "an HTTP destination must be indeterminate (expected rc 2), got $rc"

  proj=$(make_project customport https://github.com:8443/owner/repo.git)
  fm_github_ctx_intake "$proj" push '' '' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a non-default HTTPS port must be indeterminate (expected rc 2), got $rc"

  proj=$(make_project defaultport https://github.com:443/owner/repo.git)
  out=$(fm_github_ctx_intake "$proj" push '' '') || fail "an explicit default HTTPS port must remain verifiable"
  [ "$out" = "$(printf 'github.com\trepository\towner/repo')" ] || fail "an explicit default HTTPS port must resolve the canonical destination"
  pass "intake rejects unverifiable HTTP transports and accepts explicit HTTPS port 443"
}

test_intake_resolves_org_membership_selection() {
  local proj out
  proj=$(make_project org https://github.com/owner/repo.git)
  out=$(fm_github_ctx_intake "$proj" api-org-membership github.com acme) || fail "an org-membership selection must resolve"
  [ "$out" = "$(printf 'github.com\torganization\tacme')" ] || fail "org selection must carry the organization as the target, got '$out'"
  fm_github_ctx_intake "$proj" api-org-membership github.com '' >/dev/null 2>&1
  [ "$?" -eq 1 ] || fail "org-membership selection without an organization is a hard error"
  fm_github_ctx_intake "$proj" api-org-membership github.com 'bad/org' >/dev/null 2>&1
  [ "$?" -eq 1 ] || fail "org-membership selection with a malformed organization is a hard error"
  pass "intake resolves organization membership and refuses missing or malformed organizations"
}

# --- gate -------------------------------------------------------------------

# Run the gate for a project with its configured fake gh, returning its rc;
# captures stdout in GATE_OUT and whether gh was invoked in GATE_PROBED (0 probed,
# 1 not).
run_gate() {  # <proj> <forge> <host> <kind> <target> <cap> <org> <recorded>
  local proj=$1; shift
  GH_LOG="$proj/gh.log"; : > "$GH_LOG"
  GATE_OUT=$(GH_LOG="$GH_LOG" PATH="$proj/fakebin:$PATH" \
    fm_github_ctx_gate "$proj" "$@" 2>/dev/null)
  GATE_RC=$?
  if [ -s "$GH_LOG" ]; then GATE_PROBED=0; else GATE_PROBED=1; fi
}

test_gate_verifies_a_fresh_matching_destination() {
  local proj
  proj=$(make_project gatefresh https://github.com/owner/repo.git)
  install_fake_gh "$proj"  # default: active, auth ok, push true
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 0 ] || fail "a fresh matching destination with push access must verify (rc $GATE_RC)"
  [ "$GATE_OUT" = 'github|github.com|repository|owner/repo|push' ] || fail "the gate must return the verified tuple, got '$GATE_OUT'"
  [ "$GATE_PROBED" -eq 0 ] || fail "a fresh verification must probe"
  pass "the gate probes and verifies a fresh matching destination, returning its tuple"
}

test_gate_reprobes_even_when_the_recorded_tuple_matches() {
  local proj vt
  proj=$(make_project gatereprobe https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|repository|owner/repo|push'
  # A recorded tuple that byte-equals the observed destination is NOT trusted as
  # a probe shortcut: the gate always re-probes the current account so an
  # account switch on an unchanged destination is caught here, not at push time.
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 0 ] || fail "a recorded tuple matching a currently-authorized destination must still verify (rc $GATE_RC)"
  [ "$GATE_OUT" = "$vt" ] || fail "the gate must return the verified tuple, got '$GATE_OUT'"
  [ "$GATE_PROBED" -eq 0 ] || fail "the gate must re-probe even when the recorded tuple matches"
  pass "the gate re-probes a matching recorded tuple rather than trusting it as a shortcut"
}

test_gate_catches_an_account_switch_on_an_unchanged_destination() {
  local proj vt
  proj=$(make_project gateacctswitch https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|repository|owner/repo|push'
  # The destination is unchanged and its recorded tuple matches, but the active
  # gh account has been switched to one that lacks push access to the target.
  # Because the gate re-probes under the CURRENT account, this is caught at the
  # gate (a concrete access failure, rc 1) instead of failing later at git push.
  set_fake_gh "$proj" active=1 auth=ok push=false
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 1 ] || fail "an account switch that loses push access must block at the gate as a concrete access failure (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 0 ] || fail "catching the account switch requires re-probing the matching tuple"
  # A signed-out active account on an otherwise-matching tuple is likewise caught.
  set_fake_gh "$proj" active=1 auth=notlogged
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 1 ] || fail "a signed-out account on a matching tuple must block at the gate (rc $GATE_RC)"
  pass "an account switch on an unchanged destination is caught at the gate, not at push time"
}

test_gate_blocks_unverifiable_transports_before_fast_path() {
  local proj vt url
  vt='github|github.com|repository|owner/repo|push'
  for url in http://github.com/owner/repo.git https://github.com:8443/owner/repo.git https://other-user@github.com/owner/repo.git ssh://root@github.com/owner/repo.git ssh://git@github.com:2222/owner/repo.git; do
    proj=$(make_project gatebadtransport "$url")
    install_fake_gh "$proj"
    run_gate "$proj" github github.com repository owner/repo push '' "$vt"
    [ "$GATE_RC" -eq 2 ] || fail "an unverifiable transport must block indeterminate before the fast path (rc $GATE_RC, URL $url)"
    [ "$GATE_PROBED" -eq 1 ] || fail "an unverifiable transport must block without probing (URL $url)"
  done
  pass "the gate blocks unverifiable HTTP, HTTPS userinfo, ports, and SSH authorities before its fast path"
}

test_gate_accepts_standard_github_ssh_authorities() {
  local proj out url
  for url in git@github.com:owner/repo.git ssh://git@github.com/owner/repo.git ssh://git@github.com:22/owner/repo.git; do
    proj=$(make_project gatessh "$url")
    out=$(fm_github_ctx_intake "$proj" push '' '') || fail "a standard GitHub SSH authority must resolve (URL $url)"
    [ "$out" = "$(printf 'github.com\trepository\towner/repo')" ] || fail "a standard GitHub SSH authority resolved incorrectly (URL $url)"
  done
  pass "intake accepts standard GitHub SSH authorities"
}

test_gate_observes_effective_push_routing() {
  local proj vt branch out planned fork_vt
  vt='github|github.com|repository|owner/repo|push'
  planned='fm/planned-task'

  proj=$(make_project gateplannedbranch https://github.com/owner/repo.git)
  git -C "$proj" remote add alternate https://gitlab.example/owner/repo.git
  git -C "$proj" config branch.historical.pushRemote alternate
  out=$(fm_github_ctx_intake "$proj" push '' '' "$planned") || fail "an unrelated branch push route must not block the planned branch"
  [ "$out" = "$(printf 'github.com\trepository\towner/repo')" ] || fail "the planned branch must resolve the verified origin"
  git -C "$proj" config "branch.$planned.pushRemote" origin
  fm_github_ctx_intake "$proj" push '' '' "$planned" >/dev/null || fail "a planned branch explicitly routed to origin must remain verifiable"
  git -C "$proj" remote add fork https://github.com/fork/repo.git
  git -C "$proj" config "branch.$planned.pushRemote" fork
  out=$(fm_github_ctx_intake "$proj" push '' '' "$planned") || fail "a planned branch routed to a GitHub fork must resolve"
  [ "$out" = "$(printf 'github.com\trepository\tfork/repo')" ] || fail "intake must observe the effective fork destination"
  install_fake_gh "$proj"
  fork_vt='github|github.com|repository|fork/repo|push'
  run_gate "$proj" github github.com repository fork/repo push '' '' "$planned"
  [ "$GATE_RC" -eq 0 ] || fail "the effective GitHub fork destination must verify (rc $GATE_RC)"
  [ "$GATE_OUT" = "$fork_vt" ] || fail "the gate must return the effective fork tuple"
  [ "$GATE_PROBED" -eq 0 ] || fail "the effective GitHub fork must be probed"
  run_gate "$proj" github github.com repository owner/repo push '' "$vt" "$planned"
  [ "$GATE_RC" -eq 2 ] || fail "an effective fork that mismatches the recorded repository must block"
  [ "$GATE_PROBED" -eq 1 ] || fail "a mismatched effective fork must block before probing"
  git -C "$proj" remote set-url --add --push fork https://github.com/fork/repo.git
  git -C "$proj" remote set-url --add --push fork https://github.com/other/repo.git
  fm_github_ctx_intake "$proj" push '' '' "$planned" >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an effective remote with multiple push destinations must be indeterminate"

  proj=$(make_project gatepushdefault https://github.com/owner/repo.git)
  git -C "$proj" remote add alternate https://gitlab.example/owner/repo.git
  git -C "$proj" config remote.pushDefault alternate
  install_fake_gh "$proj"
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "remote.pushDefault must route observation away from origin and block (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a non-origin push default must block before probing the recorded origin"

  proj=$(make_project gatebranchpush https://github.com/owner/repo.git)
  git -C "$proj" remote add alternate https://gitlab.example/owner/repo.git
  branch=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" config "branch.$branch.pushRemote" alternate
  install_fake_gh "$proj"
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "branch pushRemote must route observation away from origin and block (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a non-origin branch push remote must block before probing the recorded origin"

  proj=$(make_project gatebranchremote https://github.com/owner/repo.git)
  git -C "$proj" remote add alternate https://gitlab.example/owner/repo.git
  branch=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" config "branch.$branch.remote" alternate
  install_fake_gh "$proj"
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "branch tracking remote must route observation away from origin and block (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a non-origin branch tracking remote must block before probing the recorded origin"

  proj=$(make_project gatefetchroute https://github.com/owner/repo.git)
  git -C "$proj" remote add upstream https://github.com/upstream/repo.git
  branch=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" config "branch.$branch.remote" upstream
  out=$(fm_github_ctx_intake "$proj" fetch '' '') || fail "fetch intake must resolve the branch tracking remote"
  [ "$out" = "$(printf 'github.com\trepository\tupstream/repo')" ] || fail "fetch intake must observe the effective tracking remote"

  pass "the gate observes effective push and fetch remotes"
}

test_gate_blocks_a_changed_or_ambiguous_destination_without_adopting_it() {
  local proj vt
  proj=$(make_project gatechanged https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|repository|owner/repo|push'
  # host changed: selection is github.com, remote is now enterprise
  git -C "$proj" remote set-url origin https://github.enterprise.example/owner/repo.git
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "a changed destination host must block indeterminate (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a changed host must not probe the unselected destination"

  # repository changed under the same host
  git -C "$proj" remote set-url origin https://github.com/owner/other.git
  run_gate "$proj" github github.com repository owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "a changed repository must block indeterminate (rc $GATE_RC)"
  pass "the gate blocks a changed host or repository and never adopts the unselected destination"
}

test_gate_reprobes_when_the_verified_record_is_missing() {
  local proj
  proj=$(make_project gatemissing https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  # no recorded tuple (legacy/erased): must re-probe, not trust
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 0 ] || fail "a missing verified record must re-probe and can verify (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 0 ] || fail "a missing verified record must force a probe (fail-closed migration)"
  pass "a missing verified record forces a re-probe rather than a trusted launch"
}

test_gate_classifies_auth_and_indeterminate_failures() {
  local proj
  proj=$(make_project gateauth https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  # not logged in -> needs auth (rc 1)
  set_fake_gh "$proj" active=1 auth=notlogged
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 1 ] || fail "a signed-out probe must block as a concrete auth failure (rc $GATE_RC)"
  # write access denied -> access required (rc 1)
  set_fake_gh "$proj" active=1 auth=ok push=false
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 1 ] || fail "denied write access must block (rc $GATE_RC)"
  # network failure -> indeterminate (rc 2), never a login prompt
  set_fake_gh "$proj" active=1 auth=network
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 2 ] || fail "a network failure must be indeterminate, not a login prompt (rc $GATE_RC)"
  # gh cannot isolate the active account -> indeterminate
  set_fake_gh "$proj" active= auth=ok
  run_gate "$proj" github github.com repository owner/repo push '' ''
  [ "$GATE_RC" -eq 2 ] || fail "an account-isolation gap must be indeterminate (rc $GATE_RC)"
  pass "the gate classifies signed-out, access-denied, network, and account-isolation failures correctly"
}

test_gate_blocks_a_capability_target_kind_mismatch_before_fast_path() {
  local proj vt
  proj=$(make_project gatemismatch https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|organization|acme|fetch'
  run_gate "$proj" github github.com organization acme fetch acme "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "a fetch capability with an organization target must block indeterminate (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a malformed capability-target pairing must block before probing"
  pass "the gate blocks a mismatched capability and target kind before its fast path"
}

test_gate_blocks_a_malformed_organization_before_fast_path() {
  local proj vt
  proj=$(make_project gatebadorg https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|organization|bad/org|api-org-membership'
  run_gate "$proj" github github.com organization '' api-org-membership 'bad/org' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "a malformed organization must block indeterminate (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a malformed organization must block before probing or trusting the tuple"
  pass "the gate blocks a malformed organization before its fast path"
}

test_gate_blocks_a_malformed_repository_owner_before_fast_path() {
  local proj vt
  proj=$(make_project gatebadowner https://github.com/bad_owner/repo.git)
  install_fake_gh "$proj"
  vt='github|github.com|repository|bad_owner/repo|push'
  run_gate "$proj" github github.com repository bad_owner/repo push '' "$vt"
  [ "$GATE_RC" -eq 2 ] || fail "a malformed repository owner must block indeterminate (rc $GATE_RC)"
  [ "$GATE_PROBED" -eq 1 ] || fail "a malformed repository owner must block before probing or trusting the tuple"
  pass "the gate blocks a malformed repository owner before its fast path"
}

test_gate_reports_when_gh_is_not_installed() {
  local proj err rc no_gh_bin command_path command_name
  proj=$(make_project gatenogh https://github.com/owner/repo.git)
  no_gh_bin="$proj/no-gh-bin"
  mkdir -p "$no_gh_bin"
  # Preserve the gate's real Git and URL-normalization behavior.
  # Make gh deterministically absent even when a CI image installs it in /usr/bin.
  for command_name in git tr; do
    command_path=$(command -v "$command_name") || fail "required test command $command_name is unavailable"
    ln -s "$command_path" "$no_gh_bin/$command_name"
  done
  err=$(PATH="$no_gh_bin" fm_github_ctx_gate "$proj" github github.com repository owner/repo push '' '' 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a gate without gh must block indeterminate (rc $rc)"
  case "$err" in
    *"GH_AUTH_INDETERMINATE: the gh CLI is not installed"*) ;;
    *) fail "a gate without gh must emit its indeterminate bootstrap diagnostic, got '$err'" ;;
  esac
  pass "the gate reports an indeterminate bootstrap diagnostic when gh is not installed"
}

test_owner_refusals_emit_bootstrap_diagnostics() {
  local proj out rc
  proj=$(make_project diagnostics https://github.com/owner/repo.git)

  out=$(fm_github_ctx_intake "$proj" push Bad_Host '' 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a malformed asserted host must refuse"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "a malformed asserted host must emit a bootstrap diagnostic" ;; esac

  out=$(fm_github_ctx_intake "$proj" push github.enterprise.example '' 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "an asserted host mismatch must refuse"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "an asserted host mismatch must emit a bootstrap diagnostic" ;; esac

  out=$(fm_github_ctx_intake "$proj" api-org-membership github.com '' 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a missing organization must refuse"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "a missing organization must emit a bootstrap diagnostic" ;; esac

  out=$(fm_github_ctx_intake "$proj" api-org-membership github.com bad/org 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a malformed organization must refuse"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "a malformed organization must emit a bootstrap diagnostic" ;; esac

  git -C "$proj" remote set-url origin https://gitlab.example/owner/repo.git
  out=$(fm_github_ctx_intake "$proj" fetch '' '' 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "an authentication scout without an asserted non-GitHub host must refuse selection"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "an authentication scout host refusal must emit a bootstrap diagnostic" ;; esac

  out=$(fm_github_ctx_gate "$proj" gitlab gitlab.example repository owner/repo push '' '' 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an unsupported recorded forge must block"
  case "$out" in *GH_AUTH_INDETERMINATE:*) ;; *) fail "an unsupported recorded forge must emit a bootstrap diagnostic" ;; esac
  pass "authentication-context owner refusals emit bootstrap diagnostics"
}

test_gate_keeps_organization_404_indeterminate() {
  local proj
  proj=$(make_project gateorg https://github.com/owner/repo.git)
  install_fake_gh "$proj"
  set_fake_gh "$proj" active=1 auth=ok org=notfound
  run_gate "$proj" github github.com organization acme api-org-membership acme ''
  [ "$GATE_RC" -eq 2 ] || fail "an organization 404 must stay indeterminate, not access-required (rc $GATE_RC)"
  pass "an organization-membership 404 stays indeterminate rather than a concrete authorization verdict"
}

test_scope_comes_from_immutable_task_identity
test_dispatch_requires_auth_is_conditional_and_fails_closed
test_capability_maps_kind_and_requirement
test_recorded_context_state_distinguishes_absent_partial_and_complete_records
test_dest_tuple_is_a_stable_delimited_join
test_intake_auto_selects_github_com_but_never_infers_another_host
test_intake_blocks_a_missing_destination_but_leaves_local_origins_ungated
test_intake_refuses_mismatch_and_ambiguity
test_intake_blocks_unrecognized_remote_transports
test_intake_rejects_unverifiable_http_transports
test_intake_resolves_org_membership_selection
test_gate_verifies_a_fresh_matching_destination
test_gate_reprobes_even_when_the_recorded_tuple_matches
test_gate_catches_an_account_switch_on_an_unchanged_destination
test_gate_blocks_unverifiable_transports_before_fast_path
test_gate_accepts_standard_github_ssh_authorities
test_gate_observes_effective_push_routing
test_gate_blocks_a_changed_or_ambiguous_destination_without_adopting_it
test_gate_reprobes_when_the_verified_record_is_missing
test_gate_classifies_auth_and_indeterminate_failures
test_gate_blocks_a_capability_target_kind_mismatch_before_fast_path
test_gate_blocks_a_malformed_organization_before_fast_path
test_gate_blocks_a_malformed_repository_owner_before_fast_path
test_gate_reports_when_gh_is_not_installed
test_owner_refusals_emit_bootstrap_diagnostics
test_gate_keeps_organization_404_indeterminate
