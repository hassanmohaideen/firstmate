#!/usr/bin/env bash
# Credentialed behavior regression for the repository-owned Playop dispatch default.
#
# This drives Pi's public instruction-loading interface against the effective
# tracked configuration and its dispatch owners. It does not parse source bytes
# or recreate natural-language matching in shell.
set -u

if [ "${FM_PLAYOP_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PLAYOP_DISPATCH_LIVE_E2E=1 to run the credentialed Playop dispatch regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-playop-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$PROJECT/defaults" "$PROJECT/.agents/skills/harness-adapters" \
  "$PROJECT/.agents/skills/quota-array-dispatch" "$PROJECT/docs"
cp "$ROOT/AGENTS.md" "$PROJECT/AGENTS.md"
cp "$ROOT/defaults/crew-dispatch.json" "$PROJECT/defaults/crew-dispatch.json"
cp "$ROOT/.agents/skills/harness-adapters/SKILL.md" \
  "$PROJECT/.agents/skills/harness-adapters/SKILL.md"
cp "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
  "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"
cp "$ROOT/docs/configuration.md" "$PROJECT/docs/configuration.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" add .

out=$(
  cd "$PROJECT" &&
    pi --print --approve --no-session --no-extensions --no-skills \
      --model openai-codex/gpt-5.6-sol --thinking high \
      "Read the tracked Firstmate instructions, dispatch default, and referenced dispatch owners in this project. Evaluate each independent intake under the stated evidence, without running vendor or quota commands. Return exactly the ten requested lines and no prose. (1) A genuinely ambiguous Playop architecture migration can materially change the design; no override exists; catalogs and authentication are usable: AMBIGUOUS=<harness>|<model>|<effort>. (2) A bounded, well-understood Playop remediation has an explicit path; no override exists: BOUNDED=<harness>|<model>|<effort>. (3) An independent adversarial security and final-diff review of Playop is requested, and the existing Pi review tuple openai-codex/gpt-5.6-sol is catalog-supported and usable: REVIEW_FABLE_REQUIRED=<yes|no> and REVIEW_SOL_ELIGIBLE=<yes|no>. (4) The captain explicitly overrides one Playop implementation to Codex GPT; OVERRIDE=<wins|loses>. A future local rule is equally specific to bounded Playop remediation and selects Codex; LOCAL_OVERRIDE=<wins|loses>. (5) An authoritative probe concretely proves the selected Claude credential unusable for Playop while the safe interactive commands are claude auth login and claude auth status; LOGIN_REQUEST=<command>, SILENT_REROUTE=<yes|no>, and VERIFY=<command>. (6) The only authentication evidence is an unmodeled Claude source and quota uncertainty: UNCERTAIN_LOGIN=<yes|no>. Use the generic effort fallback for an omitted effort axis."
) || fail "Pi instruction run failed: $out"

for required in \
  'AMBIGUOUS=claude|fable|xhigh' \
  'BOUNDED=claude|fable|low' \
  'REVIEW_FABLE_REQUIRED=no' \
  'REVIEW_SOL_ELIGIBLE=yes' \
  'OVERRIDE=wins' \
  'LOCAL_OVERRIDE=wins' \
  'LOGIN_REQUEST=claude auth login' \
  'SILENT_REROUTE=no' \
  'VERIFY=claude auth status' \
  'UNCERTAIN_LOGIN=no'
do
  printf '%s\n' "$out" | grep -Fxq "$required" \
    || fail "expected line '$required', got: $out"
done

printf '%s\n' "$out"
printf '%s\n' "ok - Playop matching, precedence, profile axes, review carve-out, and authentication interaction"
