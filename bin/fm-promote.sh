#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# A promoted scout becomes a ship push, so its push destination is verified now
# through bin/fm-github-context-lib.sh (the same owner as fm-spawn): github.com is
# auto-selected, an Enterprise host is gated only when firstmate asserts it with
# --github-host, a non-GitHub or local-only push is not gated, and a blocked
# verification refuses the promotion rather than flipping the contract. The
# resolved selection and verified destination are written into the promoted meta.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--github-host <canonical-host>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-github-context-lib.sh
. "$SCRIPT_DIR/fm-github-context-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
GITHUB_HOST=
GITHUB_HOST_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      github-host) GITHUB_HOST=$a; GITHUB_HOST_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --github-host) want_value=github-host ;;
    --github-host=*) GITHUB_HOST=${a#--github-host=}; GITHUB_HOST_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac
[ "$GITHUB_HOST_SET" -eq 0 ] || [ -n "$GITHUB_HOST" ] || { echo "error: --github-host requires a non-empty value" >&2; exit 1; }
if [ "$GITHUB_HOST_SET" -eq 1 ]; then
  fm_github_validate_hostname "$GITHUB_HOST" || { echo "error: --github-host must be a lowercase canonical hostname" >&2; exit 1; }
fi

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# A promoted scout becomes a ship push, so its push destination is verified now
# through the one owner (bin/fm-github-context-lib.sh), exactly like a fresh ship
# intake: github.com is auto-selected, an Enterprise host is gated only when
# firstmate asserts it with --github-host, and a non-GitHub or local-only push is
# not gated. A blocked verification refuses the promotion rather than flipping the
# contract. Any scout-only authentication selection is dropped and re-derived for
# the ship push.
PROMOTE_WORKTREE=$(awk -F= '$1 == "worktree" { print substr($0, index($0, "=") + 1); exit }' "$META" 2>/dev/null)
GH_GATED=0
GH_FORGE=
GH_SEL_HOST=
GH_TARGET_KIND=
GH_TARGET=
GH_VERIFIED_DEST=
if [ "$MODE" != local-only ]; then
  if [ -z "$PROMOTE_WORKTREE" ] || [ ! -d "$PROMOTE_WORKTREE" ]; then
    echo "GH_AUTH_INDETERMINATE: the recorded worktree cannot be resolved for GitHub write-access verification" >&2
    echo "error: GitHub write-access verification for task $ID is indeterminate; promotion is waiting" >&2
    exit 1
  fi
  if GH_INTAKE=$(fm_github_ctx_intake "$PROMOTE_WORKTREE" push "$GITHUB_HOST" ""); then
    IFS=$'\t' read -r GH_SEL_HOST GH_TARGET_KIND GH_TARGET <<EOF
$GH_INTAKE
EOF
    GH_FORGE=github
    GH_GATED=1
  else
    GH_INTAKE_RC=$?
    case "$GH_INTAKE_RC" in
      3) GH_GATED=0 ;;
      1) exit 1 ;;
      *)
        echo "error: GitHub write-access verification for task $ID is indeterminate; promotion is waiting" >&2
        exit 1
        ;;
    esac
  fi
  if [ "$GH_GATED" -eq 1 ]; then
    if GH_VERIFIED_NEW=$(fm_github_ctx_gate "$PROMOTE_WORKTREE" "$GH_FORGE" "$GH_SEL_HOST" "$GH_TARGET_KIND" "$GH_TARGET" push "" "$GH_VERIFIED_DEST"); then
      GH_VERIFIED_DEST=$GH_VERIFIED_NEW
    else
      GH_GATE_RC=$?
      if [ "$GH_GATE_RC" -eq 1 ]; then
        echo "error: GitHub authentication or write access blocks task $ID; promotion is waiting" >&2
      else
        echo "error: GitHub write-access verification for task $ID is indeterminate; promotion is waiting" >&2
      fi
      exit 1
    fi
  fi
fi

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' \
  -e '^gh_gated=' -e '^gh_forge=' -e '^gh_selected_host=' -e '^gh_target_kind=' -e '^gh_target=' \
  -e '^gh_auth_required=' -e '^gh_auth_capability=' -e '^gh_organization=' -e '^gh_verified_dest=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "gh_gated=$GH_GATED"
  if [ "$GH_GATED" -eq 1 ]; then
    echo "gh_forge=$GH_FORGE"
    echo "gh_selected_host=$GH_SEL_HOST"
    echo "gh_target_kind=$GH_TARGET_KIND"
    [ -z "$GH_TARGET" ] || echo "gh_target=$GH_TARGET"
    [ -z "$GH_VERIFIED_DEST" ] || echo "gh_verified_dest=$GH_VERIFIED_DEST"
  fi
} >> "$TMP"
mv "$TMP" "$META"
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
