# ADR 0024 — `/batch` parallel ritual orchestrator

- Status: Accepted (amended by [ADR 0037](0037-walk-before-gates-iterative.md) — parallelization splits into two waves bracketing the serial walk gate: `--phase=build` (terminal `built`) → operator walks each task → `--phase=gates` (terminal `reviewed`))
- Date: 2026-04-22
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0005 — Parallel tasks via worktrees](0005-parallel-tasks-via-worktrees.md), [ADR 0012 — Raise parallel build cap to 6](0012-raise-parallel-build-cap-to-6.md), [ADR 0013 — Local `/check` parity](0013-local-check-parity.md), [ADR 0018 — Collapse walk fast-path into review](0018-collapse-walk-fastpath-into-review.md)
- Amended by: [ADR 0037 — Reorder `/walk` to immediately after `/build`](0037-walk-before-gates-iterative.md)

## Context

The ritual `/plan-next → /build → /check → /review → /walk → /ship` is strictly serial per task in the operator's mental model: one task is selected, built, checked, reviewed, (walked), shipped, and only then is the next selected. With ~33 tasks shipped and MASTERPLAN's parallel-work cap of 6, the bottleneck is **operator context-switching overhead between commands**, not any one command's runtime.

Everything downstream of `/build` is already built for safe parallelism:

- Worktrees are per-task ([ADR 0005](0005-parallel-tasks-via-worktrees.md)) — no file-level contention.
- Sidecars are per-task ([ADR 0021](0021-reduce-context-bloat-buildlog-followups.md)) — no markdown-table contention.
- `scripts/set-worktree-project-id.sh` mints per-worktree Supabase project IDs ([ADR 0013](0013-local-check-parity.md)) — no Docker-name contention.
- The reviewer subagent prompt is self-contained and bias-free by design ([ADR 0018](0018-collapse-walk-fastpath-into-review.md)) — N reviewers can run concurrently without cross-contamination.
- `/review` already fast-paths non-UX prefixes (F-\*, SC-\*, BP-\*, PR-\*) from `reviewed` → `walked` inline ([ADR 0018](0018-collapse-walk-fastpath-into-review.md)) — so for those prefixes, `/review` is the last automated gate before `/ship`.

Only `/ship` is a hard serialization point (single `.ship.lock` + GitHub merge queue). Everything before it parallelises trivially.

## Decision

Add one new slash command — `/batch <ID1> <ID2> [...] [--limit N] [--stop-on-fail]` — that dispatches `/build → /check → /review` in parallel across multiple tasks, one `general-purpose` subagent per task, organised into waves of size `--limit` (default 3, hard cap 5). No other ritual changes.

Implementation lives entirely in `.claude/commands/batch.md`. No script, agent, or sidecar schema changes.

### Scope

- Each task runs in its own `.worktrees/<id-lowercase>/` as a fresh `/build` (no `--adopt`).
- Each subagent runs the full `/build → /check → /review` sequence verbatim against the three existing skill files.
- Success terminal state per task:
  - UX prefix (LI-\*, CH-\*, AG-\*, AU-\*) → `reviewed` (needs human `/walk`).
  - Non-UX prefix (F-\*, SC-\*, BP-\*, PR-\*) → `walked` (ready to `/ship`).
- `/batch` hands control back to Jerry. `/walk` and `/ship` remain serial and human-gated.

### Concurrency caps

Four caps, all enforced by `/batch` preflight:

| Cap                         | Value                        | Rationale                                                                                                                                                                                                                          |
| --------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--limit` default           | **3**                        | Roughly half of MASTERPLAN's parallel-work cap (6) — leaves headroom for Jerry's own interactive work in the primary checkout.                                                                                                     |
| `--limit` hard ceiling      | **5**                        | Below MASTERPLAN's 6 so the cap is additive, not overlapping. Above 5 is rejected loudly; relax only by ADR + evidence of zero resource contention.                                                                                |
| Max SC-\* per wave          | **1**                        | `pnpm check:sc` boots a local Supabase (Docker). Project-ID collision is already solved by [ADR 0013](0013-local-check-parity.md); port-level collision is not. Until port allocation is dynamic, keep SC-\* serial within a wave. |
| Same package-root collision | **reject or --stop-on-fail** | Two tasks editing the same package root will likely hit merge-time conflicts; flag at preflight rather than waste an entire wave.                                                                                                  |

### Non-goals (explicitly out of scope)

- **No `/batch-ship`.** `/ship` is already serialised by `.ship.lock` + GitHub merge queue. A serial `for ID in $IDS; do /ship $ID; done` is functionally identical. No new machinery adds speedup.
- **No change to `/review`'s pass/fail criteria.** Same PRD §9.3/§9.4 checks, same design-token checks, same coverage threshold, same security-reviewer dispatch rules. Only the dispatcher changes.
- **No task bundling.** One task = one branch = one PR = one squash commit — unchanged. Bundled "campaign" PRs are a separate design question (explicitly not addressed here).
- **No relaxing of PRD §9.3/§9.4 non-negotiables.** They remain hardcoded in the agent prompt.
- **No `--adopt` support in `/batch`.** Drift recovery is inherently one-off; run `/build --adopt <ID>` serially, then `/batch` the rest.
- **No automatic retry.** Failed tasks stay at their last sidecar status; Jerry resumes via `/build --adopt` or `/check` serially.

## Consequences

### Positive

- Operator context-switching cost drops from O(N) to O(1) for the common "kick off a handful of independent tasks, walk away" flow.
- For non-UX prefixes (F-\*, SC-\*, BP-\*, PR-\*), `/batch` takes a task all the way to `walked` in one invocation — Jerry returns to a queue of tasks ready to `/ship`.
- No change to ritual state machine, sidecar schema, BUILDLOG format, or commit trailer. `/batch` output is indistinguishable from serial output once shipped.
- Follow-up promotion ([ADR 0006](0006-followup-promotion.md) / [ADR 0020](0020-batch-dispositions-ship-step-7-5.md)) still fires per-task at `/ship` Step 7.5 — exactly the "derive new tasks to follow up in rituals again" flow Jerry asked for.
- Purely additive: delete `.claude/commands/batch.md` to roll back; no state to migrate.

### Negative

- **Resource contention risk.** N parallel builds spawn N node_modules, N Docker containers (for SC-\* via `check:sc`), N Playwright chromium instances (for LI-\*/CH-\*). Laptop thermals and disk I/O may surface regressions `/batch` didn't exist to cause. Mitigated by `--limit 3` default and per-prefix caps.
- **Reviewer model cost.** Running N Sonnet/Opus reviewer subagents concurrently multiplies the per-batch LLM spend linearly with wave size. Accept the cost — reviewer quality is non-negotiable.
- **Failure triage cost.** A wave of 5 that fails 2 produces 2 parallel failure investigations; the main conversation must not conflate their diffs. Mitigated by `/batch`'s structured JSON aggregation (each task reports its own `stage` + `notes`).
- **No cross-task coordination.** If tasks A and B both independently add the same utility file, neither subagent knows; conflict surfaces at `/ship` rebase time. Mitigated by the "same package-root" preflight flag.

### Neutral

- `/walk` is still manually invoked for UX prefixes. That's by design — the human-in-the-loop gate ([ADR 0007](0007-human-in-the-loop-walk.md)) is the whole point of `/walk`, not overhead to be eliminated.
- The `--limit` and SC-\*-per-wave caps are intentionally conservative. Tighten or loosen by amending this ADR once data exists.

## Implementation note

Landed 2026-04-22 as a direct edit — this is harness tooling (`.claude/commands/`) outside the build ritual, not a product task. No MASTERPLAN row, no sidecar, no BUILDLOG entry. Future product tasks that want to depend on `/batch` (unlikely — `/batch` has no user-facing surface) would cite this ADR.

Files touched:

- `.claude/commands/batch.md` — new (the command).
- `decisions/0024-batch-parallel-ritual.md` — this ADR.
- `CLAUDE.md` — one-line mention alongside the ritual diagram.
- `MASTERPLAN.md` — one-line mention under "Parallel work".

No agent, script, sidecar, or skill-file changes.

## Verification

1. **Single-task parity.** `/batch F-XX` (for any eligible `todo` F-\* task) ends at `status: walked` with the same sidecar shape, branch name, and commit trail as `/build F-XX && /check F-XX && /review F-XX` run serially.
2. **Two-task parallel, no collision.** `/batch F-XX BP-YY` (distinct package roots) ends with both at `walked`. `git worktree list` shows both worktrees; both sidecars correct; no shared file edited twice.
3. **SC-\* wave cap.** `/batch SC-A SC-B --limit 3` produces a preflight that places SC-A in wave 1 and SC-B in wave 2. Two SC-\* are never dispatched concurrently.
4. **Failure isolation.** Seed a task with a failing test; `/batch <good> <bad>` ends good at `walked`, bad at `failed` (sidecar stuck at `built`). No cascade. `--stop-on-fail` causes wave 2 to not dispatch.
5. **Rollback.** `rm .claude/commands/batch.md` removes `/batch` from the skill surface. All existing commands still work. No orphaned state.
6. **Real-world measurement.** 3 unblocked tasks via `/batch --limit 3`, compared against the same 3 run serially. Target: ≥2× wall-clock speedup on 3-task batches.
