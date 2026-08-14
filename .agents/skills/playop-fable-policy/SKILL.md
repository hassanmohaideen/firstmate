---
name: playop-fable-policy
description: >-
  Agent-only policy for commissioning and supervising Playop work through Claude Code with Fable.
  Load before routing, sequencing, reviewing, remediating, or validating any Playop task.
user-invocable: false
metadata:
  internal: true
---

# playop-fable-policy

This skill is the single full owner of Firstmate's project-scoped Playop execution policy.
The tracked rules in `defaults/crew-dispatch.json` make its worker profile portable, while `AGENTS.md` carries only the load trigger.
Apply the generic intake, delivery, approval, and supervision contracts in `AGENTS.md` except where this policy deliberately makes a stricter Playop choice.

## Worker and quota boundary

Keep every Playop implementation, architecture, investigation, remediation, independent domain review, independent security review, coverage review, and pre-gate validation task on Claude Code with Fable.
Apply the concrete effort class selected by the best-fit tracked Playop dispatch rule.
This worker route does not govern no-mistakes gate agents.
An explicit current captain override still has the precedence defined by `AGENTS.md` and `docs/configuration.md`.
Quota exhaustion never silently routes Playop work to another provider or a weaker model.
If the selected Claude/Fable route cannot proceed, stop and report the concrete constraint and its consequence.
Enabling paid usage credits is a concrete captain decision, never an inferred remedy for exhausted quota.
Authentication or quota uncertainty alone keeps Claude/Fable eligible under the normal dispatch evidence contract and never triggers a speculative login or provider change.

## Context discipline

Start from accepted evidence already bound to the work, including reports, contracts, commits, fixtures, and exact file maps.
Do not commission broad Explore, Plan, or codebase-mapping subagents, and do not repeat discovery that accepted evidence has already settled.
Use one implementation context for each lane and keep that context through its focused implementation and owner remediation.
Read only the targeted files and history needed for the lane.
When the task brief explicitly authorizes RTK compact orientation, prefer targeted Firstmate-owned RTK compact reads and confirm every safety, mutation, validation, review, cleanliness, and approval conclusion from the corresponding raw command.
Open fresh contexts only for required independent review roles so those reviews remain independent of implementation reasoning.

## Effort classes

Use `medium` for bounded contract, protocol, UI, fixture, documentation, test, straightforward remediation, and independent review work.
Use `high` for battle resolution and work whose accepted scope changes or verifies source-side privacy, persistence, authorization, replay, or authoritative undo behavior.
Use `xhigh` only for genuinely unresolved architecture whose answer can materially change the design.
Never select `max` by default.
Do not lower effort merely to conserve usage when the task remains in a stronger class.

## Sequencing and concurrency

Complete producer contracts and other dependencies before starting consumer lanes that rely on them.
Keep genuinely independent work concurrent, including authoritative undo when it has no unresolved dependency on another lane.
Treat same-file overlap as a reconciliation risk, not a reason to serialize otherwise independent work.
Serialize only for a real semantic dependency or another unsafe shared-state condition under the general concurrency contract.

## Implementation and final validation

Run focused tests while implementing each lane and while applying owner remediation.
After all accepted changes and remediations are present, run the complete backend and frontend suites, lint, strict typing, and the production build on the exact final head before opening the PR.
Do not skip, truncate, or substitute partial tests for any required complete suite.
CI must repeat every required check before merge, and red work never merges.

## Review topology

Run the required independent domain and security reviews concurrently in fresh contexts after the implementation is reviewable.
Return findings to the implementation owner for remediation rather than letting review contexts make competing edits.
Run exactly one coverage review.
Request a targeted specialist re-review only when a correction changes a foundational state, serialization, privacy, authorization, or replay contract.
Do not add another complete manual re-review layer before no-mistakes.
No-mistakes is the final complete-diff review and owns its normal tests, documentation, PR, and CI flow.
No-mistakes may use its configured provider, including Codex, for that review, its tests, delivery validation, and CI handling.
Do not force no-mistakes internal agents through crew-dispatch configuration.

## Invariants under usage pressure

Lower usage must never weaken accepted scope, server authority, privacy, deterministic replay, final testing, CI, or merge safety.
Reduce rediscovery, duplicate contexts, and unnecessary review breadth before considering any change to execution cost.
If the accepted guarantees cannot be completed safely within the available route, report the blocker instead of silently narrowing them.
