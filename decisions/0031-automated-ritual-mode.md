# ADR 0031 — Automated ritual mode (`/auto`)

- Status: Accepted (amended by [ADR 0037](0037-walk-before-gates-iterative.md) — yield point relocates from post-review `reviewed` to post-build `built`; strict re-walk policy added: any `chore: auto-fix` or `chore: polish` commit applied after `walked` reverts the sidecar to `built` with a `stale` `walk_notes` step)
- Date: 2026-04-24
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0005 — Parallel tasks via worktrees](0005-parallel-tasks-via-worktrees.md), [ADR 0007 — Human-in-the-loop `/walk`](0007-human-in-the-loop-walk.md), [ADR 0018 — Collapse walk fast-path into review](0018-collapse-walk-fastpath-into-review.md), [ADR 0024 — `/batch` parallel ritual](0024-batch-parallel-ritual.md)
- Amended by: [ADR 0037 — Reorder `/walk` to immediately after `/build`](0037-walk-before-gates-iterative.md)

## Context

The ritual today is fully human-driven: `/plan-next → /build → /check → /review → /walk → /ship` runs one command per operator turn. Each green step requires the operator to type the next. `/batch` exists but only fans `/build → /check → /review` out in parallel; it stops at `reviewed`/`walked` and never drives `/walk` or `/ship` (ADR 0024).

Pain points observed across 30+ shipped tasks:

1. **Green-path turn tax.** On a fully green task, the operator still issues 5–6 ritual commands serially, each returning control so the next can fire. Nothing is gained from the manual re-dispatch when gates pass.
2. **Trivial gate failures interrupt flow.** A format-only `lint` failure or a 2-line review finding pauses the operator to type `/check` or fix-then-`/review` again, when the agent already has enough context to auto-fix and re-run.
3. **Follow-up noise at `/ship`.** Step 7.5 prompts Jerry for disposition on every bullet, even when the reviewer has flagged trivial in-scope polish the agent could (and should) have fixed inline.

What is genuinely human:

- **`/walk` for UX prefixes (LI-_, CH-_, AG-_, AU-_)** — someone has to drive the dev server and eyeball the UX (ADR 0007).
- **Out-of-scope follow-up dispositions** — promote/fold/drop/resolved judgment requires knowing the roadmap (ADR 0006).

Everything else on the green path is a mechanical state transition that the agent can drive, provided failure-handling and yield points are explicit.

## Decision

Introduce a new slash command **`/auto <ID>`** that drives one task through the ritual as a status-driven state machine, pausing only at human-gated yield points.

### Scope

- **Eligible prefixes:** all (F-_, SC-_, BP-_, PR-_, LI-_, CH-_, AG-_, AU-_). Prefix-aware yield points preserve existing human gates.
- **Not eligible:** tasks with `status` outside `{todo, planned, built, reviewed, walked}`. `in-progress` on another worktree is refused. `patched`/`shipped`/`reverted`/`blocked` are terminal.
- **One task per invocation.** No parallel fan-out — that is `/batch`'s job. After a ship, `/auto` auto-picks the next eligible task via `/plan-next` and continues in the same session (like `/loop`, but state-driven). Operator sends any message to halt cleanly at the next step boundary.

### State machine

Driven entirely by `.taskstate/<ID>.json.status`. Transitions dispatch the existing skill files — `/auto` adds no new ritual semantics, only composition + retry + yield.

```
todo ──(AG-*/LI-*)──> /plan-build ──> planned
 │                                      │
 ├──────────────────────────────────────┘
 │
 └─> /build ──> built ──> /check ──(retry≤3)──> green
                                                  │
                                           /review ──(retry≤2)──> Pass
                                                  │
                                ┌─────────────────┤
                                v                 v
                        UX: reviewed      non-UX: walked
                                │                 │
                     *** YIELD ***                │
                  (walk briefing)                 │
                  operator /walk                  │
                                │                 │
                                v                 │
                   walked ──────────────────────-─┤
                                                  v
                                               /ship
                                                  │
                                ┌─────────────────┤
                                v                 v
                  out-of-scope followups   no out-of-scope
                                │                 │
                        *** YIELD ***             │
                      (Step 7.5 brief)            │
                      operator disposes           │
                                │                 │
                                └─────────────────┤
                                                  v
                                              shipped
                                                  │
                                                  v
                                      /plan-next → next task
```

### Yield points

Two, exactly:

1. **UX task at `reviewed`** — agent emits the walk briefing (summary + classified follow-ups + next-command hint). Operator runs `/walk <ID>` in a normal turn. On success, operator runs `/auto --continue <ID>` (or `/auto` picks it up via status scan); agent resumes from `walked`.
2. **Any task at `/ship` Step 7.5 when out-of-scope follow-ups exist** — agent presents the existing Step 7.5 prompt, pre-tagged with scope classifier + suggested disposition. Operator picks as usual. Agent completes ship.

If neither condition fires (non-UX task with no out-of-scope follow-ups), `/auto` drives straight through `shipped` without pausing.

### Auto-fix policy

**After `/check` fails** — read `.taskstate/artifacts/<ID>/gate-summary.json`:

| Failing gate          | Auto-fix action                                                                               | Cost             |
| --------------------- | --------------------------------------------------------------------------------------------- | ---------------- |
| `format: fail`        | run `pnpm format`, stage, re-run `/check`                                                     | 1 retry          |
| `lint: fail`          | run project lint auto-fix (`pnpm lint --fix` or language-equivalent), re-run `/check`         | 1 retry          |
| `typecheck: fail`     | read failing file:line, attempt targeted fix, commit `chore: auto-fix typecheck <ID>`, re-run | 1 retry          |
| `tests: fail`         | read failing test output, fix implementation (never the test assertion), commit, re-run       | 1 retry          |
| `build: fail`         | read failing module, attempt fix, commit, re-run                                              | 1 retry          |
| `task_specific: fail` | surface immediately — task-specific gates require human judgment                              | 0 retries (STOP) |

**After `/review` fails** — parse reviewer's numbered findings list:

- For each blocker with file:line: attempt targeted fix, commit `chore: auto-fix review <ID>`, re-run `/review`. Costs 1 retry.
- Budget: **2 retries total** for review.

**Absolute retry budgets per `/auto` invocation:** 3 on check, 2 on review. No reset.

**Auto-fix safety:**

- Never run `--no-verify`, `--amend`, `git reset`, or destructive git operations.
- Never edit migrations, schema files (`supabase/migrations/*`, `*.sql`), or RLS policies inside auto-fix — those are operator-only.
- Each auto-fix commit ≤20 lines diff. Larger fix required → STOP and surface.
- If same gate/finding fails across retries in the same way → STOP (no infinite "try harder"). This is the "PRD may need an ADR" signal from ADR 0008.

### Follow-up classification

When `/review` Passes, the reviewer returns a `Follow-ups:` numbered list (file:line per ADR 0008). `/auto` classifies each bullet deterministically:

**In-scope** if ALL:

- Bullet references a path in `git diff --name-only main...HEAD`, OR same directory root (first two segments) as any path in the diff.
- Estimated fix ≤3 lines based on bullet text (a single rename, a token swap, a missing prop, a style nit).

**Out-of-scope** otherwise.

**Handling:**

- **Trivial in-scope nits (≤3 lines, same module):** agent auto-fixes in the worktree, commits as `chore: polish <ID>`, runs a light `/check`. Recorded in sidecar `follow_ups[]` as `{ "text": "<bullet>", "disposition": "resolved", "target": "<ID>", "decided": "<date>" }` so `/ship` Step 7.5 does not re-prompt for them.
- **Non-trivial in-scope OR any out-of-scope:** surfaced at the next yield point (walk briefing for UX, Step 7.5 for non-UX) with a suggested disposition (promote/fold/drop/resolved). Operator decides.

Classification is file-path + line-count heuristic, not LLM judgment. Ambiguous cases default to **surface**.

### Invocation surface

- `/auto <ID>` — drive task `<ID>` from current sidecar status.
- `/auto` (no arg) — run `/plan-next` internally, pick the top candidate, brief Jerry (one line: ID + subject + approach summary), and begin.
- `/auto --continue <ID>` — explicit resume after a manual `/walk`. Sidecar must be `walked`.
- `/auto --chain` — after each ship, keep running (`/plan-next` → next task) until no eligible task exists or Jerry sends any message.

Default without `--chain` is "stop after one task shipped". The chain mode is opt-in to keep blast radius bounded.

### Concurrency + locking

- `/auto` reuses `.ship.lock` verbatim at the ship step. No new lock.
- Before any dispatch, `/auto` reads `.taskstate/<ID>.json`: if `status: in-progress` and the recorded `worktree` isn't the current one, refuse (session B cannot hijack session A's work).
- `/auto` never fans out — one task at a time, sequential, no parallel dispatch.

### Halt contract

Any Jerry message during `/auto` aborts at the next step boundary. Agent reports: current sidecar status, last gate result, branch, worktree, and awaits instruction. No partial-state corruption — every step transition is atomic (sidecar flip happens inside the dispatched skill, not between them).

## Consequences

### Positive

- **Green path is friction-free.** A typical F-_ or SC-_ shipping cleanly runs `/auto <ID>` → shipped, zero extra turns. Operator reclaims 4–5 turns per task on the happy path.
- **Trivial failures don't stall flow.** Format/lint auto-fix happens inline; operator only hears about it via the summary.
- **UX walk stays sacred.** The one thing that requires human eyes (ADR 0007) remains fully operator-gated. Auto mode adds a structured briefing that makes the walk faster, not the walk itself.
- **Step 7.5 noise drops.** In-scope polish is auto-resolved with an audit trail; only genuine roadmap decisions surface.
- **Reversibility preserved.** Each auto-fix is its own atomic commit inside the task branch; squash still produces a single shippable commit. Revert-by-SHA still works.

### Negative / risks

- **Silent auto-fix blind spot.** Agent makes changes between `/review` and the operator's next turn. Mitigation: every auto-fix commit appears in `git log` on the worktree; walk briefing + Step 7.5 briefing both enumerate them explicitly.
- **Classification false negatives.** A truly in-scope follow-up classified as out-of-scope surfaces noise; a false in-scope classification auto-applies a change Jerry didn't see. Mitigation: line-count + path heuristic defaults to surface on ambiguity. If the heuristic proves wrong, tune via ADR.
- **Retry budget may mask real problems.** If `/check` keeps failing and eats 3 retries on the same gate, `/auto` stops and surfaces — it does not pretend green. Same terminal behavior as manual retry; the budget caps wasted compute.
- **Chain mode runaway.** `/auto --chain` could shipping-march through the whole backlog unattended. Mitigation: any Jerry message halts; chain mode is opt-in; `/plan-next` still applies eligibility gates (deps, service provisioning, branch/worktree conflicts).

### Neutral

- **No new sidecar schema.** Existing `status`, `follow_ups[]`, `walk_notes`, `updated_at` fields are sufficient. A transient `auto_mode: true` flag may appear on the sidecar during an active `/auto` run to let `/ship` Step 7.5 skip re-prompting bullets already resolved inline; it is cleared at ship completion.
- **Existing skills untouched.** `/build`, `/check`, `/review`, `/walk`, `/ship`, `/plan-next` retain their current contracts. `/auto` is pure composition.
- **`/batch` unchanged.** Parallel fan-out for the `/build → /check → /review` arc remains `/batch`'s job. Jerry can still drive `/walk` and `/ship` serially after `/batch`, or use `/auto` per ready task.

## Alternatives considered

1. **Extend `/loop` with a ritual preset.** `/loop` is interval-driven; the ritual is event-driven (state transitions). Awkward state machine on top of a scheduler. Rejected.
2. **Auto-chain inside each existing skill.** E.g. `/check` calls `/review` on green, `/review` calls `/walk`, etc. Spreads orchestration logic across six files; each skill grows a "what should I call next?" block. Rejected.
3. **Dispatch subagent per step.** Each ritual step as an independent subagent with its own context. Loses the sidecar/artifact context between steps; expensive; breaks the retry loop which needs access to the last gate's output. Rejected in favor of in-session dispatch.
4. **Human confirmation at every transition.** The most conservative option — still pause between every green step, just don't re-type the command. Barely different from today; doesn't address the turn tax. Rejected.

## Adoption

- Land as **BP-15** with this ADR as the reference.
- No migration — new command, no edits to existing sidecars.
- `CLAUDE.md` ritual note updated in the same commit.
- `.claude/commands/ship.md` gains an additive `auto_mode` detection in Step 7.5 (skips bullets already `resolved` by inline polish); manual `/ship` unchanged.
- Rollout: use on next 3 BP-_ / F-_ / SC-\* tasks in sequence. If retry loops misbehave or classification mis-fires, revert this ADR and BP-15 together (single squash commit per ritual).

## Never

- Never ship a task without the operator having run `/walk` on UX prefixes. `/auto` cannot fabricate `walk_notes` for UX tasks — that would violate ADR 0007.
- Never auto-dispose an out-of-scope follow-up. Only `resolved` (inline-fixed) may be written by the agent.
- Never auto-fix across `--amend`, migrations, RLS, or schema. Those are operator-only.
- Never continue after retry budget exhaustion. Surface and stop.
- Never dispatch `/auto` on a task whose sidecar says `in-progress` on a worktree other than the current session's — that's a sign of a parallel run.
