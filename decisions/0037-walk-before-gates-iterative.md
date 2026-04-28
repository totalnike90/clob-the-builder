# ADR 0037 — Reorder `/walk` to immediately after `/build` (before `/check` + `/review`)

- Status: Accepted
- Date: 2026-04-26
- Deciders: Jerry Neo (PM/owner)
- Supersedes parts of: [ADR 0018 — Collapse walk fast-path into review](0018-collapse-walk-fastpath-into-review.md) (the prefix-aware fast-path inside `/review` is removed; the walk-skip moves back into `/walk` itself)
- Amends: [ADR 0007 — Human-in-the-loop `/walk`](0007-human-in-the-loop-walk.md) (walk position changes from "between /review and /ship" to "immediately after /build, before /check + /review"), [ADR 0024 — `/batch` parallel ritual](0024-batch-parallel-ritual.md) (parallelization splits into two waves bracketing the serial walk gate), [ADR 0031 — Automated ritual mode (`/auto`)](0031-automated-ritual-mode.md) (yield point relocates from post-review to post-build; strict re-walk policy added on auto-fix drift)

## Context

Under the v2 ritual `/plan-next → /build → /check → /review → /walk → /ship` (per ADR 0007), `/walk` was the last gate before `/ship`. For UX-touching prefixes (`LI-*`, `CH-*`, `AG-*`, `AU-*`), this meant we burned a full gates pass and an independent reviewer pass before the operator first saw the feature in a browser. When `/walk` then surfaced a visual or interaction defect, any code change to fix it invalidated the gate run and the review — wasted compute and stale signal. The operator either had to re-run `/check` + `/review` after each tweak, or accept that the shipped diff differed from what the reviewer evaluated.

A second pain point came from ADR 0018's fast-path collapse: for non-UX prefixes (`F-*`, `SC-*`, `BP-*`, `PR-*`), `/review`'s Pass flipped sidecar directly to `walked` (skipping the `reviewed` waypoint) while writing a synthetic `n/a — non-user-facing` `walk_notes` entry. This optimization saved one commit per non-UX task but required `/review` to know about prefix taxonomy and write `walk_notes` — a mixing of concerns that complicated `/review`'s contract.

## Decision

### 1. Reorder the ritual

```
/plan-next  →  /build  →  /walk  →  /check  →  /review  →  /ship
```

`/walk` runs immediately after `/build`. For UX prefixes, the operator iterates `/build`-then-`/walk` against the worktree dev server until visually satisfied; then `/check` and `/review` run once on the locked-in code.

### 2. New status lattice

```
todo < planned < in-progress < built < walked < reviewed < shipped
```

- `/build`: `in-progress → built`.
- `/walk` (UX, all-pass): `built → walked`. Any-fail keeps `built`; operator iterates.
- `/walk` (non-UX): `built → walked` automatic skip. Synthetic `walk_notes` step `n/a — non-user-facing` is written by `/walk` (was: by `/review` per ADR 0018).
- `/check`: no status flip (unchanged from current behavior — see check.md `Never`); emits `gate-summary.json`.
- `/review`: `walked → reviewed` on Pass — uniformly across all prefixes. ADR 0018's prefix-aware fast-path is removed; the walk-skip lives in `/walk` upstream.
- `/ship`: requires `reviewed` (was `walked`). Squash-merge mechanics unchanged.

The legacy `checked` status was never written to sidecars (`/check` does not flip status). It survives in `scripts/doctor.py` LATTICE for back-compat (mapped alongside `walked`) but emits no new occurrences.

### 3. Strict re-walk policy on auto-fix drift

`/auto` (per ADR 0031) auto-fixes `/check` and `/review` failures with bounded `chore: auto-fix <gate>` and `chore: polish` commits. Under the new ritual, those commits arrive after `walked` — the operator's walk approval is then on a diff that no longer matches what will ship.

To preserve the invariant "walk approval matches the diff that ships", `/auto`'s auto-fix loop now:

1. Reverts sidecar `walked → built` whenever it commits a code-mutating fix.
2. Appends a `stale` step to the latest `walk_notes[]` attempt (or pushes a new attempt): `{ "step": "<gate> mutated code after walk", "result": "stale", "note": "auto-fix <gate> at <sha>; re-walk required" }`.
3. Yields at the walk gate again for UX prefixes; auto-redispatches `/walk` (which auto-skips, refreshing the synthetic note) for non-UX.

The `stale` step result is system-generated. Only `/auto` writes it; `/walk` itself never emits it.

### 4. `/batch` two-phase split

`/batch` parallelization splits at the serial walk gate:

- **Wave 1** (`--phase=build`, default): parallelizes `/build` across N tasks. Terminal: `built`.
- **Walks** (serial, between waves): operator runs `/walk <ID>` per task. UX is interactive; non-UX auto-skips quickly.
- **Wave 2** (`--phase=gates`, invoked after walks): parallelizes `/check + /review` across now-walked tasks. Terminal: `reviewed`.

`/ship` remains fully serial under `.ship.lock` + the merge queue. The two-phase split preserves walk-first benefit for batched UX work without breaking the parallelism cap or the strict re-walk policy.

### 5. `/blitz` is unchanged

`/blitz` skips both `/review` and `/walk` (per ADR 0032/0034). The reorder does not affect it. Only the Fold validator's non-terminal status enumeration was updated to reflect the new lattice ordering.

## Consequences

### Positive

- UX iteration is decoupled from gate signal. The operator visually approves the feature before paying for `/check` + `/review`. When walk surfaces a defect, the gates haven't yet been spent.
- Walk approval always matches the diff that ships. Strict re-walk on auto-fix drift closes the previous gap where post-review fixes silently changed shipped code.
- Single ritual, single state machine. ADR 0018's prefix-aware fast-path inside `/review` is removed; `/review`'s contract returns to "Pass → reviewed, Fail → stay" uniformly. The walk-skip for non-UX moves into `/walk` itself, where it belongs.
- Lattice is monotonic and clearer: `built < walked < reviewed`. No more prefix-conditional ordering (`reviewed < walked` for UX vs `walked < reviewed` for non-UX under ADR 0018).
- `/batch` two-phase split makes the human gate explicit in the orchestrator's contract; the previous "/batch parallelizes /build → /check → /review" hid the implicit serial walk that operators had to remember.

### Negative / risks

- **Gate signal happens later in the ritual.** Under the old order, a typecheck or build failure was caught before the operator started visually inspecting. Now the operator may spin up the dev server on code that doesn't compile — `pnpm dev` shows the error in terminal/browser, the operator fixes, re-walks. The mitigation is that walk explicitly does not require a green check (per walk.md), and the dev server's compile-on-the-fly behavior surfaces the error immediately.
- **`/auto` `chore: polish` flow now triggers re-walk.** Trivial in-scope follow-up auto-application now invalidates a prior walk and forces a yield. This is the price of the strict re-walk policy. Operators who want frictionless polish can do it manually outside `/auto` (the audit-visible commit is unchanged).
- **`/batch` users now invoke twice** (`--phase=build` then `--phase=gates` after walks). For non-UX-only batches the walks are auto-skips and the operator can chain manually; for UX batches the per-task walk was always serial under ADR 0024 anyway — the split just makes it explicit.
- **One in-flight ADR (0018) is materially superseded** rather than fully retired. Future readers must read 0018 + 0037 together to understand the historical fast-path and where the skip-marking lives now.

### Neutral

- Sidecar schema unchanged. `walk_notes[]` array shape unchanged (canonical per ADR 0008). Adds one new `step.result` enum value: `"stale"`, system-generated by `/auto` only.
- BUILDLOG copy of `walk_notes` unchanged.
- Commit trailer (`Task: <ID>` + PRD-refs + Slice) unchanged.
- `.ship.lock` and merge-queue mechanics unchanged.
- `/patch` and `/plan-build` are unchanged (neither touches the walk position).

## Files changed by this ADR

- `CLAUDE.md` — ritual block, walk semantics, lattice.
- `.claude/commands/build.md` — regression-guard lattice, `/walk` next pointer.
- `.claude/commands/walk.md` — preflight=built, non-UX auto-skip path, iteration semantics, `stale` reservation.
- `.claude/commands/check.md` — preflight=walked.
- `.claude/commands/review.md` — preflight=walked, ADR 0018 fast-path removed, Pass uniformly flips `reviewed`.
- `.claude/commands/ship.md` — preflight=reviewed.
- `.claude/commands/auto.md` — state machine reorder, yield at `built` for UX, strict re-walk policy on auto-fix drift.
- `.claude/commands/batch.md` — two-phase split (`--phase=build` / `--phase=gates`).
- `.claude/commands/doctor.md` — in-flight status set, stranded-inflight wording.
- `.claude/commands/blitz.md` — Fold validator non-terminal set.
- `scripts/doctor.py` — LATTICE swap, NON_TERMINAL set.

## Verification

1. **Lattice migration audit.** `git grep -E "(built|walked|checked|reviewed)" .claude/commands/ scripts/ decisions/ CLAUDE.md` — every occurrence is intentional under the new lattice.
2. **Single-task happy path.** Pick a fresh `LI-*` task. Run `/build → /walk → /check → /review → /ship`. Verify each command's preflight accepts the new upstream status, sidecar transitions match `built → walked → reviewed → shipped`, BUILDLOG entry shows walk attempts before gate logs.
3. **Single-task non-UX.** Pick a fresh `SC-*` or `BP-*` row. Run the same sequence. Verify `/walk` auto-skips with synthetic notes (no dev server start), and the sidecar reaches `walked` without operator intervention.
4. **Iteration loop.** On the LI-\* task above, deliberately fail a walk step (e.g. dev server has wrong copy), edit the file in the worktree, re-run `/walk`. Verify second attempt appends to `walk_notes[]` and (when fixed) flips to `walked`.
5. **`/auto` re-walk drift.** Run `/auto LI-*`, let it yield at `built`, complete walk, then artificially fail `/check` (introduce an unused import). Verify auto-fix runs and the sidecar drops back to `built` with a `stale` `walk_notes` entry, and `/auto` yields again at walk.
6. **`/batch` two-phase.** `/batch SC-x SC-y BP-z` (all non-UX, walks auto-skip). Verify wave 1 builds in parallel, walks auto-skip serially, `/batch SC-x SC-y BP-z --phase=gates` runs gates+review in parallel, terminal state `reviewed` matches single-task flow.
7. **`/doctor` invariants.** Run `/doctor` after each verification. No drift reported. Stranded-inflight check fires correctly when worktree is `walked` or `reviewed` and main is `todo`.
8. **`/blitz` regression.** Run a small `/blitz` session. Confirm zero behavior change (still skips `/check`'s heavy gates, `/review`, `/walk`).

## Alternatives considered

1. **Keep ADR 0018's fast-path; only change UX position.** Walk-before-check applies only to LI-/CH-/AG-/AU-; non-UX still routes through `/review`'s prefix-aware fast-path. Rejected — two ritual variants is more nuanced and harder to reason about than one unified flow with a one-line skip in `/walk`.
2. **Keep `/auto`'s re-walk policy lenient.** Auto-fix logs a note but does not revert `walked`. Rejected — walk approval would no longer match the diff that ships, eroding the human-judgment trail's load-bearing role.
3. **Skip `/batch` redesign; document operator-driven walks before `/batch`.** Operators walk pre-batch for UX, then run `/batch` as today. Rejected — loses parallelism for the common batched-UX flow and contradicts the rest of the ritual reorder.
4. **Defer the change behind a feature flag.** Rejected — meta-tooling change with no runtime impact; ADR-driven adoption is cheaper than carrying two ritual variants.

## Adoption

- This ADR is the meta-tooling change itself. Land via the new task branch `task/walk-before-gates-iterative` (no MASTERPLAN row — meta-ritual tooling per the BP-/process precedent).
- In-flight tasks at `status: reviewed` (UX, under the old ritual) at the time this lands can be shipped with `/ship` directly; the new `/ship` preflight accepts `reviewed`.
- In-flight tasks at `status: walked` (under the old ritual: passed through `/walk` after `/review`, ready to ship) need to first run `/check` + `/review` again (since the new `/ship` requires `reviewed`). Document the migration in BUILDLOG when the first such task hits the new flow.
- No sidecar migration required — the schema is unchanged. `walk_notes` arrays from old runs remain valid.
