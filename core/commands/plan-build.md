---
description: Write a short pre-build plan for tasks whose prefix has `pre_build_plan_gate: true` and flip the sidecar to `planned`. Usage — /plan-build <TASK-ID>
argument-hint: <TASK-ID>
---

You are writing a pre-build plan for task **$ARGUMENTS**. This command is the *pre-build* gate — "is this the right thing to build?" Answered cheaply before any code exists. Never touches code, branches, or worktrees.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Scope

- **Eligible prefixes:** any prefix whose `pre_build_plan_gate: true` in `ritual.config.yaml` (typically the higher-blast-radius prefixes — agent surfaces, larger UX surfaces). Any other prefix → stop and tell the user no plan gate is required; run `/build <ID>` directly. Detect via:
  ```bash
  TASK_PREFIX="$(echo "$ARGUMENTS" | cut -d- -f1)"
  NEEDS_PLAN="$(bash .claude/ritual/scripts/ritual-config.sh prefix.pre_build_plan_gate "$TASK_PREFIX")"
  if [ "$NEEDS_PLAN" != "true" ]; then
    echo "${ARGUMENTS} does not require a plan gate — run /build ${ARGUMENTS} directly."
    exit 0
  fi
  ```
- **Read-only filesystem.** Only writes: `.taskstate/<ID>.plan.md` (new) and a single `status` flip on `.taskstate/<ID>.json`.
- **No subagent dispatch.** The plan is the operator's artifact; auto-review would defeat its purpose.

## Preflight

Run from the main checkout at repo root.

1. Parse `$ARGUMENTS` as the task ID. If missing, stop.
2. Confirm the task's prefix has `pre_build_plan_gate: true` (see Scope above). Otherwise: `"${ID} does not require a plan gate — run /build ${ID} directly."`
3. Read `MASTERPLAN.md` to confirm the task exists and note `Deps`, `PRD`.
4. Read `.taskstate/<ID>.json`. If `status ≠ todo`, stop and report the current state.
5. For each ID in `Deps`, read its sidecar. Each must have `status: shipped` or `status: patched`. Missing deps → stop.

## Gather

6. Read the PRD section(s) in the task's `PRD` column (`{{paths.prd}}`).
7. For UX-prefixed tasks: open the prototype (`{{paths.prototypes}}/main.jsx`) and the design system README (`{{paths.design_system}}/README.md`) for voice.
8. Re-read any non-negotiable rules referenced by this task in `.claude/ritual/reviewer.project.md`. Note any clause the task touches.

## Write the plan

Create `.taskstate/<ID>.plan.md`. **Hard cap: 40 lines.** Template:

```markdown
# Plan — <ID> <subject>

**PRD:** <§ numbers + user story IDs>
**Deps:** <list, all shipped/patched>

## Approach (3–6 sentences)
<how the task will be implemented, referencing prototype / design tokens / non-negotiable rules where relevant>

## Files likely touched
- <path> — <why>
- <path> — <why>

## Test strategy
- <happy path assertion>
- <failure mode assertion>
- <prefix-specific assertion, e.g. screenshot vs prototype, data-isolation trace>

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

- Never write code, create a branch, or spawn a worktree. `/plan-build` is read-heavy, write-cheap by design.
- Never exceed 40 lines. A larger plan means the task is too broad — escalate as an ADR or MASTERPLAN split, not a longer plan.
- Never spawn a reviewer/security subagent. The plan is a human-review artifact, not a machine-graded one.
- Never gate prefixes whose `pre_build_plan_gate: false` (or absent) through `/plan-build`. They go directly to `/build`.
