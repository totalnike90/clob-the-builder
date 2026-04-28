---
description: Drive one task through the whole ritual, auto-fixing gate/review failures and pausing only at human gates. Usage — /auto [<ID>] [--continue] [--chain]
argument-hint: [<ID>] [--continue] [--chain]
---

You are driving an **automated ritual pass** on a single task (per [ADR 0031](../../decisions/0031-automated-ritual-mode.md), amended by [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)). You act as a status-driven state machine over `.taskstate/<ID>.json`, dispatching the existing ritual skills (`/build`, `/walk`, `/check`, `/review`, `/ship`, `/plan-next`, `/plan-build`) verbatim. You add nothing to the ritual — only composition, bounded retry on failure, and explicit yield points at human gates.

This is an **orchestrator**, not a new ritual. No ritual state, no gate, no reviewer criterion changes. You compose existing skills in-session.

## Parse arguments

`$ARGUMENTS` is a whitespace-separated list. Extract:

- `ID` — first token matching `^[A-Z]+-\d+$` (e.g. `F-6`, `SC-15`, `LI-3`). Optional.
- `CONTINUE` — `true` iff `--continue` present. Resume a task whose sidecar is `walked` after a manual `/walk` (per ADR 0037 — yield point for UX is post-build at `built`, operator runs `/walk` to `walked`, then resumes via `--continue`).
- `CHAIN` — `true` iff `--chain` present. After `shipped`, auto-pick next via `/plan-next` and repeat until no eligible task exists or operator halts.

If `ID` is empty and `--continue` absent → run `/plan-next` internally, read its survey, pick the top eligible candidate (phase order PR→F→SC→AU→LI→AG→CH→BP, lowest ID within phase), brief the operator with one line (`<ID> — <subject>`), and proceed.

If `ID` is empty and `--continue` present → scan `.taskstate/*.json` for a sidecar in `status: walked`; if exactly one, adopt it; if zero or multiple, stop and ask which ID to continue.

## Preflight — main thread, read-only

Run from repo root (any branch/state). Do not touch worktrees or sidecars yet.

1. Read `MASTERPLAN.md`, confirm `ID` row exists. Missing → stop: "`<ID>` not in MASTERPLAN — run `/plan-next` first."
2. Read `.taskstate/<ID>.json`. Route by current status (lattice per ADR 0037: `todo < planned < in-progress < built < walked < reviewed < shipped`):
   - `todo` — default path (or `planned` path for AG-\*/LI-\* after `/plan-build`).
   - `planned` — AG-\*/LI-\* only; skip `/plan-build`, jump to `/build`.
   - `in-progress` — read `worktree`. If it points at a worktree owned by a different session (different pwd root in `git worktree list`), refuse: "`<ID>` is in-progress in `<worktree>` — not ours. Resolve serially with `/build --adopt` or abandon the sibling session." If it points at the current session's worktree, resume from `/walk` (build already finished; sidecar is `in-progress` — `/build`'s own finish step flips to `built` next, but the next ritual step is `/walk`).
   - `built` — yield point for UX prefixes (LI-\*/CH-\*/AG-\*/AU-\*) per ADR 0037. If `--continue` is absent, emit the walk briefing and stop. For non-UX prefixes (F-\*/SC-\*/BP-\*/PR-\*), dispatch `/walk` directly — it auto-skips with synthetic `walk_notes` and flips to `walked`. With `--continue` on a UX prefix, refuse: "built is not walked — run `/walk <ID>` first."
   - `walked` — jump to `/check`.
   - `reviewed` — jump to `/ship`.
   - `shipped` / `patched` — terminal. If `CHAIN`, fall through to "pick next task"; else stop: "`<ID>` already shipped."
   - `reverted` / `blocked` — stop: "`<ID>` is `<status>` — needs human decision before `/auto` can resume."
3. For `todo`/`planned` entry paths, verify deps per `/build` preflight: every `Deps` ID has sidecar `status: shipped` or `status: patched`. Missing dep → stop and name the blocking dep.
4. Verify retry budgets reset: this is a fresh invocation.

Output a preflight line to the operator before dispatching:

```
/auto <ID> — entry at status=<current>, prefix=<LI/CH/AG/AU/F/SC/BP/PR>, path=<ux-yields-at-built | non-ux-runs-through-ship>
```

## State machine — dispatch in session

Dispatch the appropriate skill by reading its file and executing it verbatim. Each skill must end with a sidecar flip; do not proceed to the next step unless the flip matches expectations.

### 1. `todo` → `planned` (AG-\*/LI-\* only)

Read `.claude/commands/plan-build.md`. Execute. Expect sidecar → `planned`. On failure, stop and surface.

### 2. `todo` (non-AG/LI) or `planned` (AG/LI) → `built`

Read `.claude/commands/build.md`. Execute (fresh path, NOT `--adopt`). Expect sidecar → `built`. On failure, stop and surface.

### 3. `built` → `walked`

**Non-UX prefixes (F-\*/SC-\*/BP-\*/PR-\*):** Read `.claude/commands/walk.md`. Execute — it auto-skips with synthetic `walk_notes` and flips sidecar → `walked`. Proceed to step 4.

**UX prefixes (LI-\*/CH-\*/AG-\*/AU-\*) — YIELD:** Emit the walk briefing and stop (see Step 6 below). Operator runs `/walk <ID>` interactively (possibly iterating /build then /walk multiple times until visually satisfied). Once sidecar reads `status: walked`, operator resumes via `/auto --continue <ID>`.

### 4. `walked` → green gates

Read `.claude/commands/check.md`. Execute. Read the emitted `.taskstate/artifacts/<ID>/gate-summary.json`.

- **All gates `pass` or `skip` (with reason):** proceed to review.
- **Any gate `fail`:** enter the **auto-fix loop** (below). After each fix, re-run `/check` and re-read `gate-summary.json`.

#### Auto-fix loop — `/check`

Retry budget: **3 total across all `/check` gates per `/auto` invocation.** Counter does not reset.

For each failing gate, attempt the mapped fix, commit, re-run `/check`:

| Failing gate | Action | Commit message |
|---|---|---|
| `format` | `pnpm format` (or `pnpm -w format`), stage touched files | `chore: auto-fix format <ID>` |
| `lint` | `pnpm lint --fix` (TS/JS) or language-equivalent; stage touched files | `chore: auto-fix lint <ID>` |
| `typecheck` | Read failing file:line from the gate's `notes` field; apply targeted fix | `chore: auto-fix typecheck <ID>` |
| `tests` | Read failing output; fix implementation (never the test assertion); if the test itself is wrong, STOP and surface | `chore: auto-fix tests <ID>` |
| `build` | Read failing module; apply targeted fix | `chore: auto-fix build <ID>` |
| `task_specific` | **STOP immediately.** Task-specific gates require human judgment — surface the failure | — |

**Auto-fix safety:**
- Never run `--no-verify`, `--amend`, `git reset --hard`, `git checkout <path>`, or any destructive git op.
- Never edit `supabase/migrations/**`, `rollbacks/**`, `*.sql`, RLS policy files, or `supabase/config.toml` inside auto-fix.
- Each auto-fix commit diff ≤20 lines. If the minimum fix is larger, STOP and surface.
- If the same gate fails the same way twice in a row, STOP (per ADR 0008 — "may need an ADR").
- Use the task trailer on every auto-fix commit:
  ```
  Task: <ID>
  PRD-refs: <same as task>
  Slice: <same as task>
  ```

**Re-walk drift detection (per ADR 0037).** Any auto-fix commit applied at this step mutates code that was already walked. Before proceeding to `/review`, the auto-fix loop MUST:

1. Revert sidecar status: `walked` → `built`.
2. Append a synthetic `stale` step to the latest `walk_notes[]` attempt (or push a new attempt if the prior one was a non-UX skip): `{ "step": "<auto-fix gate> mutated code after walk", "result": "stale", "note": "auto-fix <gate> at <commit-sha>; re-walk required" }`.
3. Refresh `updated_at`. Commit the sidecar update as part of the same `chore: auto-fix <gate> <ID>` commit (single atomic file change).
4. Yield at the walk gate (Step 6 below) — do not auto-`/check` again until the operator has re-walked.

For non-UX prefixes (F-\*/SC-\*/BP-\*/PR-\*), `stale` triggers an automatic re-dispatch of `/walk` (which auto-skips, refreshing the synthetic note) — no human yield.

When budget exhausted without green, STOP. Report which retries were used and the residual failure. Sidecar stays at `built` (post-revert) or `walked` (if no auto-fix was applied).

### 5. green gates → Pass

Read `.claude/commands/review.md`. Execute. Expect reviewer output (Pass / Fail with findings).

- **Pass:** proceed to follow-up classification (below). Sidecar will be flipped by `/review` itself → `reviewed` (for all prefixes uniformly per ADR 0037; ADR 0018's prefix-aware fast-path is gone).
- **Fail:** enter the **review auto-fix loop**.

#### Auto-fix loop — `/review`

Retry budget: **2 total per `/auto` invocation.** Counter does not reset.

For each blocker with a file:line:
- Apply the targeted fix.
- Commit as `chore: auto-fix review <ID>` with the trailer.
- Re-walk drift detection (same as `/check` auto-fix loop above): revert sidecar to `built`, append `stale` step, yield at walk for UX prefixes (auto-redispatch for non-UX). Walk approval must match the diff that ships.
- After re-walk, re-run `/check` (fast path if no code files touched) then `/review`. The `/check` re-run refreshes `.taskstate/artifacts/<ID>/gate-summary.json`; `/review`'s preflight reads the refreshed artifact as usual.

Same safety rules as `/check` auto-fix (≤20 lines, no migrations, no destructive git ops, no `--amend`, no loop on same finding).

When budget exhausted without Pass, STOP. Sidecar stays at `walked` or `built` per re-walk policy. Report findings verbatim.

### 6. UX prefix at `built` — **YIELD** (walk briefing)

Per ADR 0037, the UX walk gate is post-build (was post-review under ADR 0007). Emit the walk briefing and stop:

```
### /auto paused — <ID> is built, awaiting /walk

Summary:
  - Files touched: <N>
  - Tests added: <N>
  - Build status: built ✓ (gates not yet run — that's after walk approval per ADR 0037)

Iteration tip: edit files in the worktree and re-run /walk to append a fresh attempt
until visually satisfied. /check + /review run on the locked-in code.

Next:
  1. Run `/walk <ID>` — dev server will start, UX checklist ready.
  2. After all-pass: `/auto --continue <ID>` to run /check → /review → /ship.
```

Do not proceed past this point without explicit operator action (`/walk` run, then `/auto --continue`).

### 7. Follow-up classification (after `/review` Pass)

Read the reviewer's numbered `Follow-ups:` list from the `/review` output. For each bullet:

**In-scope if ALL hold:**
- Bullet names a path that appears in `git diff --name-only main...HEAD`, OR the bullet's named path shares its first two directory segments with any path in the diff (e.g. both under `apps/agent/tests/`).
- Bullet describes a fix estimated at ≤3 lines (a rename, a token swap, a missing prop, a single-condition guard, a one-call addition). Multi-file, multi-function, or "add tests for X" is **not** trivial.

**Out-of-scope otherwise.**

If ambiguous (can't confidently classify), default to **out-of-scope** and surface.

#### Trivial in-scope nits — auto-apply

For each trivial in-scope bullet:
1. Apply the fix in the worktree.
2. Commit as `chore: polish <ID>` with the task trailer. One commit per bullet (atomic, revertible).
3. Append to `.taskstate/<ID>.json` `follow_ups[]`:
   ```json
   { "text": "<bullet verbatim>", "disposition": "resolved", "target": "<ID>", "decided": "<YYYY-MM-DD>" }
   ```
4. **Re-walk drift detection (per ADR 0037).** Polish commits are code-mutating after `reviewed` (which itself was after `walked`). Revert sidecar `reviewed → built` and append a `stale` step entry to `walk_notes[]` exactly like the `/check` auto-fix path. Yield at walk for UX prefixes; auto-re-dispatch for non-UX.
5. After re-walk, run `/check` once (light mode is fine), then `/review` once more to land back at `reviewed`. If any gate or review regresses, revert the polish commits and surface.
6. Set sidecar flag `auto_mode: true` (transient) so `/ship` Step 7.5 knows these bullets are already dispositioned.

The "polish triggers re-walk" rule is the price of the strict re-walk policy — walk approval matches the diff that ships. If you want polish to skip the re-walk, do it manually outside `/auto` and accept the audit gap.

#### Non-trivial or out-of-scope — surface

Collect into a list with suggested dispositions:
- Describes a new task with its own deps → suggest **promote**, hint next free ID in the appropriate phase.
- Describes a gap in an existing task (scan MASTERPLAN for close matches) → suggest **fold** into that task.
- Describes a nit too small to track → suggest **drop**.
- Matches a recently-shipped task's acceptance criteria → suggest **resolved**.

These go into the Step 7.5 yield briefing at `/ship`.

### 8. `reviewed` → `shipped`

Read `.claude/commands/ship.md`. Execute verbatim.

At **Step 7.5** (triage follow-ups, pre-merge):
- If sidecar `auto_mode: true` and `follow_ups[]` contains `disposition: "resolved"` entries written by the polish loop, skip prompting for those bullets — they are already dispositioned.
- For remaining bullets (non-trivial in-scope + out-of-scope), present the Step 7.5 menu with pre-tagged suggested dispositions from the classifier output. Operator picks (per-bullet or batch per ADR 0020).
- If **zero remaining bullets** (all either absent or already resolved by polish), silently skip Step 7.5 — no prompt.

Proceed through merge, BUILDLOG append, FOLLOWUPS regen, commit, push, worktree cleanup, lock release per the existing `/ship` steps. Clear the transient `auto_mode: true` flag during the final sidecar write.

### 9. `shipped` — chain or stop

- Without `--chain`: report shipped (per `/ship` final block) and stop. Operator decides when to run `/auto` again.
- With `--chain`: run `/plan-next` internally; if an eligible task exists, brief it one-line and recurse into step 1 (preflight) with the new ID. If none eligible, report "No eligible tasks — `/auto --chain` complete."

## Halt contract

Any message from the operator during `/auto` (other than explicit step output) aborts **at the next step boundary**. Do not interrupt mid-step — sidecar flips are atomic inside each dispatched skill and must not be torn.

On halt, report:

```
### /auto halted at operator request

Current state:
  - ID: <ID>
  - Sidecar status: <status>
  - Branch: <branch>
  - Worktree: <worktree or main>
  - Last step: <build | walk-briefing | check | review | ship | plan-next>
  - Retries used: /check <n>/3, /review <n>/2
  - Re-walks triggered: <n> (per ADR 0037 strict re-walk)
  - Next step would have been: <step>
```

Then wait for instruction.

## Never

- Never skip `/walk` for UX prefixes. The human UX gate is sacred (ADR 0007, repositioned by ADR 0037 to post-build).
- Never fabricate `walk_notes`. Only `/walk` writes real attempts; only `/auto` writes `stale` step entries (per ADR 0037 re-walk policy). `/review` no longer writes `walk_notes` at all (per ADR 0037, supersedes ADR 0018's fast-path).
- Never auto-dispose an out-of-scope follow-up. Only `disposition: "resolved"` (inline polish applied) may be written by the agent; everything else is operator-decided at Step 7.5.
- Never bypass a retry-budget exhaustion. Budgets are absolute per invocation.
- Never bypass the strict re-walk policy: any code-mutating commit (auto-fix or polish) applied after `walked` reverts the sidecar to `built` with a `stale` step. Walk approval must match the diff that ships.
- Never run two `/auto` sessions on the same task. Sidecar `in-progress` on another worktree → refuse.
- Never edit `MASTERPLAN.md`, `BUILDLOG.md`, `FOLLOWUPS.md` outside the `/ship` step's own writes.
- Never use `--no-verify`, `--amend`, `git add -A`, `git reset --hard`, or any destructive git operation.
- Never edit migrations, rollbacks, RLS policies, or `supabase/config.toml` inside auto-fix — those are operator-only per ADR 0031.
- Never re-run `/review` after polish-loop commits without first re-running `/walk` and `/check` (per ADR 0037 — code mutated, walk + gates must rerun).
- Never continue past a `task_specific` gate failure — those require human judgment.
- Never force the chain. `--chain` opts in; any operator message halts the chain at the next boundary.
