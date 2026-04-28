# ADR 0032 — `/blitz` session-level ritual bypass

- Status: Accepted
- Date: 2026-04-24
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0005 — Parallel tasks via worktrees](0005-parallel-tasks-via-worktrees.md), [ADR 0007 — Human-in-the-loop `/walk`](0007-human-in-the-loop-walk.md), [ADR 0018 — Collapse walk fast-path into review](0018-collapse-walk-fastpath-into-review.md), [ADR 0029 — Ritual blast-radius scaling (`/patch` + plan gate)](0029-ritual-blast-radius-scaling.md), [ADR 0031 — Automated ritual mode (`/auto`)](0031-automated-ritual-mode.md)

## Context

The ritual (`/plan-next → /build → /check → /review → /walk → /ship`) is optimized for correctness with per-task isolation in worktrees. That's the right default, but the cost falls hardest on two shapes of work that don't fit the default:

1. **Live-iteration UX work.** Editing a component, refreshing the dev server, spotting a layout bug, fixing it, committing, repeating. Full ritual forces a worktree, `/check` gate ladder, reviewer subagent round-trip, and `/walk` human gate on top of what the operator is already doing in-browser. Doubles the wall-clock for small UX passes.
2. **Multi-feature focused sessions.** An hour spent cleaning up three related surfaces touches three MASTERPLAN rows. The existing ritual forces three separate `/build → /check → /review → /walk → /ship` loops — orchestration cost overwhelms the work.

`/patch` (ADR 0029) addresses trivial SC-\*/PR-\* changes only. `/auto` (ADR 0031) automates the ritual but still runs every gate. Neither covers the live-iteration + multi-feature shape.

Secondary need: when the operator iterates freely, MASTERPLAN row PRD refs and PRD prose itself can drift relative to what actually shipped. The full ritual catches this by construction (the reviewer reads the PRD; `/walk` surfaces mismatches). A fast-path needs an explicit reconciliation step so MASTERPLAN and the PRD don't rot.

## Decision

Add a new slash command `/blitz [--i-know]` at [`.claude/commands/blitz.md`](../.claude/commands/blitz.md). It is a **session-level** fast-path:

### Shape

- **No task ID at init.** Operator runs `/blitz` on clean `main`, picks a session slug (e.g. `reel-polish`), `/blitz` creates branch `blitz/<slug>` and a `.taskstate/_blitz.json` marker.
- **Trailer-driven task discovery at land.** Operator iterates freely, committing granular with one `Task: <ID>` trailer per commit (already a CLAUDE.md convention). Running `/blitz` a second time on the same branch triggers the land phase: scan commit trailers, compute `TASK_COMMITS` map of `ID → [shas]`, proceed per-task.
- **One squash commit per task ID on `main`.** For each discovered task, `/blitz` cherry-picks that task's commits onto `main` with `--no-commit`, then commits as `<ID>: <subject>` with a `## Journey` body listing granular subjects. 1:1 task/revert invariant preserved.
- **Cheap gates run; heavy gates skipped.** `format` + `lint` + `typecheck` run in parallel at land (same pattern as `/ship` post-rebase). Tests, build, and task-specific gates are the operator's responsibility via `pnpm dev` in-browser.
- **`/review` and `/walk` skipped.** Operator accepts personal responsibility for quality across all session tasks.
- **Per-task scope reconciliation before land.** For each covered task, `/blitz` displays a three-column summary — MASTERPLAN row PRD refs, files touched, PRD § surface hints (lightweight parse). Operator answers N (no drift) or Y (stage MASTERPLAN edits, PRD `$EDITOR` session, new-row promotion). All edits are operator-prompted — no auto-apply. Staged edits land atomically in the session's ship commit.
- **One bundled BUILDLOG entry.** Session wrapped in `<!-- TASK:BLITZ-<slug>:START/END -->` anchors, with per-task `<!-- TASK:<ID>:START/END -->` sub-blocks preserved inside. `scripts/slice-buildlog.py <ID>` continues to work.
- **Shared serialization.** Uses the same `.ship.lock` directory as `/ship` and `/patch`. `main` stays linear.

### Terminal status

New sidecar terminal value: `status: blitzed`. `[.claude/commands/build.md](../.claude/commands/build.md)` preflight accepts `blitzed` alongside `shipped` and `patched` when verifying `Deps`.

### Eligibility

- **Universal prefix eligibility** — F, SC, BP, PR, LI, CH, AG, AU. The bypass is loudest for UX prefixes (LI/CH/AG/AU) where `/walk` is normally mandatory; BUILDLOG records the bypass explicitly every time.
- **AG-\*/LI-\* plan gate still enforced** — `status: planned` required (per ADR 0029). `todo` → stop and redirect to `/plan-build <ID>`. Plan gate is the last cheap catch for scope drift before fast code.
- **Risky-surface gate** — `supabase/migrations/`, `supabase/config.toml`, `rollbacks/**`, `*.sql` outside migrations, and RLS policies outside `auth.uid() IS NOT NULL` sweeps require the `--i-know` flag. With `--i-know`, `/blitz` proceeds and BUILDLOG records the matched paths + override flag.
- **Task trailer discipline** — every granular commit must carry exactly one `Task: <ID>` trailer. Zero trailers or multi-value trailers → stop at land; fix via `git rebase -i` (no `--amend`).
- **Disjoint file surfaces across tasks in one session** — `/blitz` cherry-picks each task's commits onto `main` in sequence. Cross-task conflicts mean the session wasn't cleanly task-separable → abort all prior squashes (`git reset --hard origin/main`), release lock, redirect operator to restart as separate blitzes per task.

## Consequences

- **(a) `main` linearity preserved** via shared `.ship.lock` across `/blitz`, `/ship`, `/patch`.
- **(b) 1:1 task/revert invariant preserved** via per-task squash commits. `git revert <SQUASH_<ID>>` still undoes exactly one task cleanly; N tasks in a session → N revertable commits.
- **(c) Per-task BUILDLOG anchors preserved** inside the session wrapper — `scripts/slice-buildlog.py` unchanged.
- **(d) Operator accepts personal responsibility** for test coverage, UX verification, acceptance-criteria checking across all session tasks. `pnpm dev` in-browser replaces `/review` + `/walk`.
- **(e) Deps graph extended** — `blitzed` on par with `shipped`/`patched` for `/build` preflight.
- **(f) MASTERPLAN and PRD stay in sync with shipped behaviour** — reconciliation prompt runs per task, every session. Staged edits land atomically in the ship commit so they revert alongside the code.
- **(g) No auto-generated PRD prose** — `/blitz` opens `$EDITOR` on the PRD; operator writes the change. PRD is sacred spec text; tooling doesn't paraphrase.
- **(h) Hard wall at cross-task file conflicts** — forces operators to keep session commits task-disjoint, or split into separate blitz sessions. Matches how the rest of the ritual assumes task isolation.
- **(i) Staged reconciliation edits persist across Phase 2 retries** — `_blitz.json.staged_edits` is written to disk before the cheap-gate step, so a typecheck failure mid-land doesn't erase operator reconciliation work.

## Alternatives considered

- **Single bundled squash (all tasks, one SHA)** — breaks the 1:1 revert invariant explicitly called out in CLAUDE.md. Rejected.
- **One PR per task with parallel orchestration** — defeats "directly and quickly" intent; matches `/batch` which already covers orchestrated parallel ritual. Rejected for this niche.
- **Force task ID at init (mirror `/patch`/`/build`)** — doesn't scale to multi-task sessions; forces operator to pre-commit to a scope they discover through iteration. Rejected.
- **Relax Task trailer requirement** — makes squash-per-task mechanically impossible. Rejected (trailer is already mandatory per CLAUDE.md "Commit trailer" block).
- **Merge-commit preserving branch history** — breaks squash convention; complicates `slice-buildlog.py`; inflates `git log`. Rejected.
- **Tick-off PRD acceptance criteria at land** — heavier prompt ritual. Reconciliation here is diff-driven (what did you touch?) not criteria-driven (did you meet every line?). Operator picked diff-driven; correctness verification stays the operator's job via in-browser checks. Rejected for this command; full ritual still does criteria checks via reviewer subagent + `/walk`.
- **Auto-apply MASTERPLAN and PRD edits from heuristic detection** — too risky for spec-of-record files. Operator picked prompt-confirmed only. Rejected.
- **Hard-block migrations / config / RLS (no `--i-know`)** — too restrictive for genuine emergency patches that warrant the fast-path. Operator picked warn-and-override. Accepted: `--i-know` flag, BUILDLOG records the override every time.
- **Zero gates at land** — typecheck catches silent type drift the browser won't surface; ~5–10s cost. Operator picked format + lint + typecheck. Accepted.

## Non-goals

- Not a replacement for `/build` + `/ship`. Those remain the default for any task where correctness matters more than speed.
- Not auto-chained. Each blitz session is an explicit operator decision.
- Not for tasks with overlapping file surfaces — hard wall at cherry-pick conflicts.
- Not a way to fabricate MASTERPLAN rows — every trailer ID must exist with an eligible sidecar status.

## Revert

Remove `.claude/commands/blitz.md`, revert the `CLAUDE.md` paragraph added in the ship commit, revert the `.claude/commands/build.md` one-line dep-check edit, and drop any sidecar with `status: blitzed` back to `in-progress` + `walked: false` so the normal `/ship` flow can reclaim them. Existing shipped blitz commits on `main` stay — the terminal state is baked into the git log and BUILDLOG regardless.
