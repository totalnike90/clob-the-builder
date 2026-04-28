---
description: Write a short pre-build plan for AG-* / LI-* tasks and flip the sidecar to `planned`. Usage — /plan-build <TASK-ID>
argument-hint: <TASK-ID>
---

You are writing a pre-build plan for task **$ARGUMENTS** under [ADR 0029](../../decisions/0029-ritual-blast-radius-scaling.md). This command is the *pre-build* gate for AG-\* and LI-\* tasks — "is this the right thing to build?" Answered cheaply before any code exists. Never touches code, branches, or worktrees.

## Scope

- **Eligible prefixes:** `AG-*` and `LI-*` only. Any other prefix → stop and tell the user no plan gate is required; run `/build <ID>` directly.
- **Read-only filesystem.** Only writes: `.taskstate/<ID>.plan.md` (new) and a single `status` flip on `.taskstate/<ID>.json`.
- **No subagent dispatch.** The plan is the operator's artifact; auto-review would defeat its purpose.

## Preflight

Run from the main checkout at repo root.

1. Parse `$ARGUMENTS` as the task ID. If missing, stop.
2. Confirm prefix is `AG-*` or `LI-*`. Otherwise: `"${ID} does not require a plan gate — run /build ${ID} directly."`
3. Read `MASTERPLAN.md` to confirm the task exists and note `Deps`, `PRD`.
4. Read `.taskstate/<ID>.json`. If `status ≠ todo`, stop and report the current state.
5. For each ID in `Deps`, read its sidecar. Each must have `status: shipped` or `status: patched` (per ADR 0029). Missing deps → stop.

## Gather

6. Read the PRD section(s) in the task's `PRD` column (`../specs/SALLY-PRD-Tech-Spec.md`).
7. For LI-\* tasks: open the prototype (`../prototypes/sally-mvp-prototype.jsx`) and the design system README (`../design system/README.md`) for voice.
8. For AG-\* tasks: re-read PRD §9.3 and §9.4 — the non-negotiable agent rules. Note any clause the task touches.

## Write the plan

Create `.taskstate/<ID>.plan.md`. **Hard cap: 40 lines.** Template:

```markdown
# Plan — <ID> <subject>

**PRD:** <§ numbers + user story IDs>
**Deps:** <list, all shipped/patched ✓>

## Approach (3–6 sentences)
<how the task will be implemented, referencing prototype / design tokens / §9.3–9.4 where relevant>

## Files likely touched
- <path> — <why>
- <path> — <why>

## Test strategy
- <happy path assertion>
- <failure mode assertion>
- <for LI-*: screenshot vs prototype; for AG-*: data-isolation trace>

## Risks & open questions
- <risk — mitigation>
- <question if ambiguous; otherwise "none">
```

If the plan would exceed 40 lines, the task probably isn't single-scope — stop and recommend splitting it (follow-up ADR, not a scope override).

## Flip the sidecar

9. Update `.taskstate/<ID>.json` → `status: planned`; refresh `updated_at`. No branch, no worktree, no commit (not on a task branch — this is a main-checkout edit).

## Report

```
Plan written: .taskstate/<ID>.plan.md  (<N> lines)
Sidecar: status → planned

Review the plan. Edit in place if the direction needs correcting.
When ready, run:  /build <ID>   (build preflight will confirm `status: planned`)
```

## Never

- Never write code, create a branch, or spawn a worktree. `/plan` is read-heavy, write-cheap by design.
- Never exceed 40 lines. A larger plan means the task is too broad — escalate as an ADR or MASTERPLAN split, not a longer plan.
- Never spawn a reviewer/security subagent. The plan is a human-review artifact, not a machine-graded one.
- Never gate F-\*, SC-\*, BP-\*, PR-\*, CH-\*, AU-\* through `/plan`. They go directly to `/build` as today.
