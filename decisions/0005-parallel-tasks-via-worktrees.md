# ADR 0005 — Parallel tasks via git worktrees and taskstate sidecars

- Status: Accepted
- Date: 2026-04-19
- Deciders: Jerry Neo (PM/owner)
- Supersedes parts of: —
- Extends: [ADR 0002 — Branch-per-task + squash merge](0002-branch-per-task-squash-merge.md)

## Context

Under the original workflow, `/build <ID>` required a clean working tree on `main`, and every status flip ran through `MASTERPLAN.md`'s state columns. This forced the MVP's 85 tasks to build strictly in series:

1. Only one branch could be in flight at a time in the single working copy.
2. Two branches editing `MASTERPLAN.md` collided on column padding — markdown tables re-pad the widest cell, so even disjoint row edits merge-conflict.
3. `BUILDLOG.md` appends from parallel branches would race on the same lines.
4. `/ship` pushed `main`; two concurrent ships would lose the fast-forward.

Many tasks are genuinely independent (e.g., F-6 Go gateway, F-7 FastAPI core, F-8 agent skeleton all fan out from F-1 and touch different subtrees). Serializing them wastes throughput during an aggressive four-week build.

## Decision

Three changes, all in one commit:

### 1. Git worktrees for isolation

Each task runs in `.worktrees/<id-lowercase>/`, created by `/build` via `git worktree add -b task/<id>-<slug> .worktrees/<id> origin/main`. The main checkout stays on `main`. Worktrees live inside the repo (`.worktrees/` is gitignored) to preserve the relative paths (`../specs/`, `../design system/`, `../prototypes/`) that `plan-next` and `build` rely on, and to avoid turbo-cache fragmentation that sibling-directory worktrees would cause.

Multiple worktrees can coexist. Up to 6 concurrent builds is the working cap for one builder. (Originally 2–4; raised to 6 by [ADR 0012](0012-raise-parallel-build-cap-to-6.md) after the serialization stack proved itself in practice.)

### 2. Task state in per-ID sidecars

Task-level state (`status`, `branch`, `worktree`, `pr`, `commit`, `updated_at`) moves out of `MASTERPLAN.md` into `.taskstate/<ID>.json`. `MASTERPLAN.md` keeps the plan-level columns (`ID`, `Task`, `Deps`, `PRD`) and never changes during a build cycle.

Rationale: markdown tables are a terrible write-hot target. Every edit re-pads all rows; even a one-character status change produces a large diff and collides with any sibling edit. JSON sidecars, one file per task, never conflict — each task owns exactly one file. `/plan-next` reads every sidecar via `jq` to compute eligibility.

Seeded once by `scripts/migrate-taskstate.mjs`, which parses the pre-migration tables. The script is throwaway but kept in tree for documentation.

### 3. Ship serialization via lock + GitHub merge queue

`/ship` acquires `.ship.lock` (flock) in the main checkout before touching `main`. It rebases on `origin/main`, re-runs the essentials, then merges via `gh pr merge --auto --squash --delete-branch`. The `--auto` flag queues the merge behind checks and serializes against concurrent ships server-side. Only the lock-holder appends to `BUILDLOG.md` on `main`, so no append race is possible.

Deconfliction guarantees:

- `BUILDLOG.md` appends: impossible to conflict — only one ship holds the lock at a time, and the rebase step guarantees each append lands on top of the latest.
- `MASTERPLAN.md` writes: eliminated — ship no longer edits MASTERPLAN.
- `.taskstate/<ID>.json` writes: can't conflict — each task edits its own file.
- Remote race: GitHub merge queue (`gh pr merge --auto`) is the single authoritative serializer on the remote. `main` stays linear.

## Consequences

Good:

- Up to 6 tasks in flight at once (raised from the original 2–4 by [ADR 0012](0012-raise-parallel-build-cap-to-6.md)). Real throughput gain on independent subsystems (F-6/F-7/F-8, AG-\* nodes that depend only on AG-1, CH-\* UI tasks once CH-1 ships).
- Zero-conflict state writes by construction. The markdown-table merge pain is gone.
- Ritual from ADR 0002 preserved end-to-end: one branch per task, one squash commit, one BUILDLOG entry, one sidecar flip to `shipped`. Revert chain still works: `git revert <sha>` + BUILDLOG lookup.
- `gh pr merge --auto` is battle-tested and removes any need for a custom ship queue.

Bad:

- Worktrees add real filesystem complexity. The user must `cd .worktrees/<id>` for each task session. `/check` and `/review` now have a cwd preflight that catches "running from the wrong directory."
- Each worktree duplicates `node_modules` (pnpm handles this efficiently via hardlinks, but first-time install per worktree is not free).
- `.taskstate/` is 85 small files. A manual bulk status flip (rare) now means editing 85 files instead of 85 lines. Acceptable — flips are per-task, not bulk.

## Rejected alternatives

- **Keep MASTERPLAN authoritative, serialize rows via a deterministic formatter.** Prettier / editors will re-wrap tables on save; the conflict risk cannot be fully eliminated without custom tooling. Not worth the fight.
- **Sibling-directory worktrees (`../<repo>-<id>/`).** Breaks any relative references (specs, design system) the project may use, fragments build caches, and confuses the IDE's workspace. Rejected.
- **Contract-ready dependency state (`F-4*` meaning "can start against unmerged dep").** Adds a second status axis and a new failure mode where a task builds against a dep that later reshapes. Deferred until throughput actually proves gated on it.
- **`BUILDLOG.d/<ID>.md` per-ship files.** Not needed while the ship lock serializes appends. Revisit if conflict pressure appears.
- **Custom ship queue or job server.** Over-engineered for one builder. `flock` + `gh pr merge --auto` cover it.

## Follow-ups

- Consider `turbo --filter='...[main]'` in `/check` to only run gates for the subtree the task touched. Speeds up parallel `/check` cycles when multiple tasks converge.
- If migration-timestamp collisions ever happen (schema tasks + parallel non-schema schema edits), add a `.migrations.lock` file in `supabase/migrations/` to reserve the next timestamp atomically. Today SC-\* tasks are chain-dependent in MASTERPLAN, so the collision cannot occur.
- After ~20 successful parallel ships, revisit whether contract-ready deps are worth adding.
- Delete `scripts/migrate-taskstate.mjs` once the seed has been in place for a phase. It's a one-shot.
