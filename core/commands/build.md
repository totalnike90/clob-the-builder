---
description: Implement the given task on an isolated worktree. Usage — /build <TASK-ID> [--adopt [--resume]]
argument-hint: <TASK-ID> [--adopt [--resume]]
---

You are building task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md)). State lives in `.taskstate/<ID>.json`; build runs in `.worktrees/<id>/`. Parallel tasks may be in flight in sibling worktrees — do not touch them.

Parse `$ARGUMENTS`: first token is the task ID; optional trailing `--adopt` switches to the adoption path — for sidecar drift recovery only, when `/plan-next` flagged a branch/worktree on disk while the sidecar still says `todo`. Optional `--resume` (only valid with `--adopt`) acknowledges that the worktree branch's sidecar is *ahead* of main's view and pulls the worktree's status onto main without redoing earlier ritual steps. See the regression guard in the adoption preflight below.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Preflight — fresh build (default)

Run from repo root (any branch/state — working copy does not need to be clean).

1. Read `MASTERPLAN.md` to confirm the task exists; note `Deps` + `PRD`.
2. Read `.taskstate/<ID>.json`. Prefix-specific gating (driven by `ritual.config.yaml`):
   - Prefixes whose `pre_build_plan_gate: true` — require `status: planned` (the `/plan-build <ID>` gate must have run). `status: todo` → stop: `"Run /plan-build ${ID} first — this prefix requires a plan gate."` Other non-terminal statuses → stop unless `--adopt`.
   - Prefixes whose `pre_build_plan_gate: false` (or absent) — require `status: todo`. Anything else → stop unless `--adopt`.

   Detect via:
   ```bash
   TASK_PREFIX="$(echo "$ARGUMENTS" | cut -d- -f1)"
   NEEDS_PLAN="$(bash .claude/ritual/scripts/ritual-config.sh prefix.pre_build_plan_gate "$TASK_PREFIX")"
   ```
3. For each ID in `Deps`, read `.taskstate/<dep>.json` and confirm `status: shipped`, `status: patched`, **or `status: blitzed`** (per [ADR 0032](../../decisions/0032-blitz-fast-path.md) — patched and blitzed tasks satisfy deps identically to shipped). Missing deps → stop, report.
4. `git fetch origin`.
5. If `.worktrees/<id-lowercase>/` already exists, stop and report — clean up with `git worktree remove .worktrees/<id-lowercase>` or re-run with `--adopt`.

## Preflight — adoption path (`--adopt`)

1. Confirm `task/<ID_LC>-*` exists locally or on `origin`. If not, abort — adoption is only for drift, not cold-start.
2. Confirm `.worktrees/<ID_LC>/` exists. If not: `git worktree add .worktrees/<ID_LC> task/<ID_LC>-<SLUG>`.
3. **Regression guard.** Read the worktree branch's sidecar by inspecting the in-tree file at `.worktrees/<ID_LC>/.taskstate/<ID>.json`. Compare its `status` to what step 6 below would write (`in-progress`). Status lattice (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)):
   ```
   todo < planned < in-progress < built < walked < reviewed < shipped
   ```
   - If the worktree's status is `todo`, `planned`, or `in-progress` → proceed normally (no regression).
   - If the worktree's status is `built`, `walked`, or `reviewed` → **STOP** unless `--resume` is set. Print:
     ```
     /build --adopt would regress task <ID> from worktree status `<X>` back to
     `in-progress`, overwriting earlier ritual progress. To pull the worktree's
     status onto main without redoing earlier ritual steps, re-run with
     `/build --adopt --resume <ID>`. Otherwise, advance the ritual:
       built     → /walk <ID>
       walked    → /check <ID>
       reviewed  → /ship <ID>
     ```
   - If the worktree's status is `shipped`, `patched`, `blitzed`, `reverted`, or `blocked` → **STOP** unconditionally (terminal). `--resume` does not bypass terminal states. Run `/doctor` to diagnose; the worktree should not still exist for a terminal task.
4. `cd .worktrees/<ID_LC>` and run `hooks.post_worktree_create` from `ritual.config.yaml` if defined (project-supplied; idempotent).
5. Run `bash .claude/ritual/scripts/propagate-env-to-worktree.sh` — copies `.env.local` + any `.env.*.local` from the main checkout into the worktree so dev runs don't blank on missing env. Idempotent (never clobbers existing destination files, so per-worktree overrides survive re-runs); silent no-op on fresh clones without `.env.local`.
6. If the branch HEAD is already a `chore: start <ID>` commit, do **not** duplicate it.
7. **Sidecar write — branches on `--resume`:**
   - **Default (no `--resume`):** Update `.taskstate/<ID>.json` to `status: in-progress`, branch, worktree, refresh `updated_at`. Commit on the task branch as `chore: adopt <ID>` with the trailer block.
   - **With `--resume`:** Carry the worktree branch's existing `status` forward (do not regress to `in-progress`). Refresh `branch`, `worktree`, `updated_at`; preserve other fields. Commit as `chore: adopt <ID> (resume <X>)` where `<X>` is the preserved status, with the trailer block.
8. Skip "Start"; jump to the appropriate ritual step:
   - Default → "Build" (status `in-progress`).
   - `--resume` with `built` → operator should next run `/walk <ID>`; do not auto-advance.
   - `--resume` with `walked` → operator should next run `/check <ID>` then `/review <ID>`.
   - `--resume` with `reviewed` → operator should next run `/ship <ID>`.

## Start

Let `ID` = `$ARGUMENTS`, `ID_LC` = lowercase, `SLUG` = the kebab-case slug from `/plan-next`.

1. `git worktree add -b task/<ID_LC>-<SLUG> .worktrees/<ID_LC> origin/main`
2. `cd .worktrees/<ID_LC>` — all subsequent work here.
3. Run `hooks.post_worktree_create` from `ritual.config.yaml` if defined (project-supplied; idempotent — typically env-setup, container-naming, or local-config minting that must not collide across parallel worktrees).
4. Run `bash .claude/ritual/scripts/propagate-env-to-worktree.sh` — copies `.env.local` + any `.env.*.local` from the main checkout into the worktree so dev runs don't blank on missing env. Idempotent; silent no-op on fresh clones without `.env.local`.
5. Write `.taskstate/<ID>.json` with `status: in-progress`, `branch`, `worktree`, `pr: null`, `commit: null`, fresh `updated_at`. If `.taskstate/<ID>.plan.md` exists (plan-gated prefix), copy it into the worktree for reference during build; do not re-gate on it post-transition.
6. Commit that single-file change on the task branch as `chore: start <ID>` with the trailer block.

## Build

7. Read the PRD section(s) in the task's `PRD` column.
8. Implement the task. Stick to files in the brief unless new ones are genuinely needed — if scope creeps, stop and ask.
9. Follow `CLAUDE.md` strictly: no inventing colors/tokens/components (use `{{paths.design_system}}/`); voice rules for user-facing copy; non-negotiable rules in `.claude/ritual/reviewer.project.md` when touching the surfaces those rules cover.
10. Write tests proportional to the task. Test framework + coverage targets are project-defined (see `gates.test.cmd` in `ritual.config.yaml`). At minimum:
    - ≥1 happy-path assertion per public surface.
    - ≥1 failure-mode assertion (auth, validation, or boundary).
    - For UI surfaces: ≥1 render test plus interactive behavior coverage.
11. Commit as you go; each message ends with the trailer (keys per `commit.trailer_keys` in `ritual.config.yaml`):
    ```
    Task: <ID>
    ```
    Granular commits are fine — squashed at `/ship`.

## Finish build (not ship)

12. When acceptance criteria are met, flip `.taskstate/<ID>.json` → `status: built` with fresh `updated_at`. Commit as the final commit on the branch.
13. Report: `Built in .worktrees/<ID_LC>. cd there and run /walk <ID> next (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md) — iterate /build then /walk until visually satisfied; /check + /review run after walk approval).`

## Never

- Never `cd` out of your worktree during build. Read other tasks' files via explicit paths in the main checkout at repo root — do not modify.
- Never `--amend` — always new commits.
- Never `git add -A` — stage specific files.
- Never skip hooks.
- Never touch another task's files or another worktree. Missing dep → stop and report; do not silently fix it.
- Never commit secrets. Keep `.env` gitignored.
- Never edit `MASTERPLAN.md` during build — state lives in the sidecar.

`.taskstate/` is in the shared checkout; each task writes only its own `<ID>.json`.
