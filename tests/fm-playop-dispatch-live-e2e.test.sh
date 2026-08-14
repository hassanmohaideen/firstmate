#!/usr/bin/env bash
# Credentialed behavior regression for the repository-owned Playop dispatch policy.
#
# This drives Pi's public instruction-loading interface against the effective
# tracked configuration and its policy owners. It does not parse source bytes
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
mkdir -p "$PROJECT/config" "$PROJECT/defaults" \
  "$PROJECT/.agents/skills/harness-adapters" \
  "$PROJECT/.agents/skills/playop-fable-policy" \
  "$PROJECT/.agents/skills/quota-array-dispatch" "$PROJECT/docs"
cp "$ROOT/AGENTS.md" "$PROJECT/AGENTS.md"
cp "$ROOT/defaults/crew-dispatch.json" "$PROJECT/defaults/crew-dispatch.json"
printf '%s\n' '{"rules":[{"when":"The task is a bounded Playop remediation.","use":{"harness":"codex","model":"gpt-local","effort":"medium"}}]}' \
  > "$PROJECT/config/crew-dispatch.json"
cp "$ROOT/.agents/skills/harness-adapters/SKILL.md" \
  "$PROJECT/.agents/skills/harness-adapters/SKILL.md"
cp "$ROOT/.agents/skills/playop-fable-policy/SKILL.md" \
  "$PROJECT/.agents/skills/playop-fable-policy/SKILL.md"
cp "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
  "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"
cp "$ROOT/docs/configuration.md" "$PROJECT/docs/configuration.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" add .

out=$(
  cd "$PROJECT" &&
    pi --print --approve --no-session --no-extensions --no-skills \
      --model openai-codex/gpt-5.6-sol --thinking high \
      "Read the tracked Firstmate instructions, dispatch default, and every referenced dispatch or Playop policy owner in this project. Evaluate each independent intake under the stated evidence without running vendor or quota commands. Return exactly the fourteen requested lines and no prose. (1) Genuinely unresolved Playop architecture can materially change the design: AMBIGUOUS=<harness>|<model>|<effort>. (2) A bounded Playop protocol and UI implementation has an accepted contract and exact file map: BOUNDED=<harness>|<model>|<effort>. (3) A Playop authoritative replay remediation is required: FOUNDATIONAL=<harness>|<model>|<effort>. (4) An independent Playop security review is required: REVIEW=<harness>|<model>|<effort>. (5) Ordinary pre-gate Playop validation is bounded and no foundational contract remains unresolved: VALIDATION=<harness>|<model>|<effort>. (6) A non-Playop documentation task has no matching local rule or tracked default: NON_PLAYOP=<matched|unmatched>. (7) The captain explicitly overrides one bounded Playop implementation to Codex GPT: OVERRIDE=<wins|loses>. (8) The effective local config has a rule equally specific to bounded Playop remediation and selects Codex: LOCAL_OVERRIDE=<wins|loses>. (9) The only authentication evidence is an unmodeled Claude source and quota uncertainty for a bounded Playop task: UNCERTAIN_PROFILE=<harness>|<model>|<effort> and UNCERTAIN_LOGIN=<yes|no>. (10) Applicable quota evidence concretely proves Fable cannot start before reset and no captain override exists: EXHAUSTED_ROUTE=<blocked|other-provider>. (11) The only way to proceed before reset is enabling paid usage credits: PAID_CREDITS=<captain-decision|automatic>. (12) Lower usage would require weakening server authority or deterministic replay: WEAKEN_GUARANTEES=<yes|no>. (13) No-mistakes is running the final complete-diff review and delivery validation with Codex selected by its own configuration: GATE_CODEX=<allowed|forbidden>."
) || fail "Pi instruction run failed: $out"

for required in \
  'AMBIGUOUS=claude|fable|xhigh' \
  'BOUNDED=claude|fable|medium' \
  'FOUNDATIONAL=claude|fable|high' \
  'REVIEW=claude|fable|medium' \
  'VALIDATION=claude|fable|medium' \
  'NON_PLAYOP=unmatched' \
  'OVERRIDE=wins' \
  'LOCAL_OVERRIDE=wins' \
  'UNCERTAIN_PROFILE=claude|fable|medium' \
  'UNCERTAIN_LOGIN=no' \
  'EXHAUSTED_ROUTE=blocked' \
  'PAID_CREDITS=captain-decision' \
  'WEAKEN_GUARANTEES=no' \
  'GATE_CODEX=allowed'
do
  printf '%s\n' "$out" | grep -Fxq "$required" \
    || fail "expected line '$required', got: $out"
done

printf '%s\n' "$out"
printf '%s\n' "ok - Playop matching, precedence, effort classes, gate boundary, and quota boundaries"
