---
description: Run /build + /check + /review in parallel for multiple tasks across two waves bracketing the serial walk gate. Usage — /batch <ID1> <ID2> [...] [--limit N] [--stop-on-fail] [--phase=build|gates]
argument-hint: <ID1> <ID2> [...] [--limit N] [--stop-on-fail] [--phase=build|gates]
---

You are orchestrating a **two-phase parallel ritual pass** across multiple tasks (per [ADR 0024](../../decisions/0024-batch-parallel-ritual.md), amended by [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)). Under ADR 0037, `/walk` runs immediately after `/build` (before `/check` + `/review`), so parallel work splits at the serial walk gate:

- **Wave 1 (`--phase=build`, default for fresh invocations):** parallelizes `/build` across N tasks. Terminal: `built`.
- **Walks (serial, between waves):** operator runs `/walk <ID>` for each task — UX prefixes get a real walkthrough, non-UX prefixes auto-skip. Terminal: `walked`.
- **Wave 2 (`--phase=gates`, invoked after walks):** parallelizes `/check + /review` across the now-walked tasks. Terminal: `reviewed`.

`/walk` and `/ship` remain serial and human-gated — never run by `/batch`.

This is an **orchestrator**, not a new ritual. No ritual state, no gate, no reviewer criterion changes. You are the dispatcher that fans out to N general-purpose subagents and aggregates their results.

## Parse arguments

`$ARGUMENTS` is a whitespace-separated list. Extract:

- `IDS` — all tokens matching `^[A-Z]+-\d+$` (e.g. `F-6`, `SC-15`, `BP-14`, `LI-3`). Preserve order.
- `LIMIT` — integer after `--limit`, default **3**, hard cap **5**. Reject >5 with: "`--limit` capped at 5 — re-invoke with a smaller number or split into separate `/batch` calls."
- `STOP_ON_FAIL` — `true` iff `--stop-on-fail` present. Default `false` (independent failure — other tasks keep running).
- `PHASE` — `build` (default) or `gates`. `--phase=gates` skips wave 1, expects each ID at `status: walked`, dispatches `/check + /review` in parallel.

If `IDS` is empty → stop: "`/batch` requires at least one task ID. Usage: `/batch <ID1> <ID2> [...] [--limit N] [--stop-on-fail] [--phase=build|gates]`."

## Preflight — main thread, read-only, single-pass

Run from repo root (any branch/state). Do **not** touch any worktree or sidecar yet.

For each `ID` in `IDS`:

1. Verify `MASTERPLAN.md` contains a row for `ID`. Missing → mark as `reject: not-in-masterplan` and continue.
2. Read `.taskstate/<ID>.json`. Status check depends on `PHASE`:
   - `--phase=build` (default): require `status: todo`. Anything else → mark as `reject: status=<current>` and continue. (Adoption path is not supported by `/batch` — run `/build --adopt <ID>` serially if you need drift recovery.)
   - `--phase=gates`: require `status: walked`. Anything else → `reject: status=<current> (expected walked — run /walk <ID> first)` and continue.
3. For each ID in that row's `Deps`, read `.taskstate/<dep>.json` and confirm `status: shipped`. Any missing dep → mark as `reject: dep=<dep>@<status>` and continue.
4. **Wave 1 only:** verify `.worktrees/<id-lowercase>/` does **not** already exist on disk. Exists → mark as `reject: worktree-exists` and continue.

Then enforce concurrency rules **across the IDs list** (even before chunking into waves — these are invocation-level caps):

5. **Max 1 SC-\* per wave.** Group IDs into waves of size `LIMIT`, but within any single wave there can be at most one `SC-*` prefix (Supabase boots are port-sensitive — see ADR 0024 §Concurrency). If two SC-\* land in the same wave, push the second into the next wave. If this expands total wave count beyond the user's mental model, surface it: "Waves reshuffled due to SC-\* concurrency: wave 1 = [...], wave 2 = [...]."
6. **No two tasks touching the same package root.** Infer rough package root from PRD refs in MASTERPLAN (best-effort; if ambiguous, proceed — conflict will surface at `/check`). If two tasks obviously collide (e.g. both touch `apps/web/app/feed/`), flag and require `--stop-on-fail` to be set OR ask the user to drop one.

Output a preflight summary to Jerry **before dispatching**:

```
/batch preflight — phase=<build|gates>, <N total> IDs

  Accepted: F-6, BP-14, LI-3
  Rejected:
    - SC-20: dep=SC-19@in-progress
    - F-99: not-in-masterplan

  Waves (--limit 3):
    1. F-6, BP-14, LI-3    (no SC-* in this wave)

Dispatching wave 1...
```

If **all** IDs are rejected → stop and report. Do not dispatch.

## Dispatch — one wave at a time, all tasks in wave in parallel

For each wave, send **one message** containing N `Agent` tool calls (parallel dispatch — all calls in a single assistant message). Each agent gets `subagent_type: general-purpose` and a self-contained prompt using the template below (build phase) or the gates-phase template.

Wait for the entire wave to finish before starting the next wave.

### Subagent prompt template — `--phase=build`

Fill in the bracketed slots per task. Everything else is verbatim.

```
You are executing the SALLY MVP build phase for ONE task: <ID>.

You run in your own git worktree at .worktrees/<ID_LC>/. Parallel sibling worktrees exist for other tasks in this batch — do NOT touch them, do NOT cd out of your own worktree after setup, do NOT read their sidecars except in read-only preflight per the skill files.

Follow this skill VERBATIM:

  1. .claude/commands/build.md    — implement the task (fresh path, NOT --adopt)

Workflow contract:

  - Stop and report "failed at build" if /build preflight fails (not-todo, deps, worktree-exists)
  - Success terminal state: sidecar at `built`. Do NOT run /walk, /check, /review, /ship — those are serial or part of wave 2.

Non-negotiables:

  - Do NOT run /walk. Do NOT run /check. Do NOT run /review. Do NOT run /ship.
  - Do NOT edit MASTERPLAN.md or BUILDLOG.md. Those change only at /ship.
  - Do NOT touch other tasks' sidecars, worktrees, or branches.
  - Follow every `Never` rule in build.md. No --no-verify, no --amend, no `git add -A`.

Your LAST message must be ONLY this JSON block (no prose before or after):

{
  "id": "<ID>",
  "status": "built" | "failed",
  "stage": "build" | "done",
  "branch": "<task branch name>" | null,
  "worktree": "<worktree path>" | null,
  "notes": "<short summary, <200 chars>"
}
```

### Subagent prompt template — `--phase=gates`

```
You are executing the SALLY MVP gates phase for ONE task: <ID>.

The task is already at sidecar `status: walked` — wave 1 (/build) and the serial walk gate are complete. You run in the existing worktree at .worktrees/<ID_LC>/. Parallel sibling worktrees exist for other tasks in this batch — do NOT touch them.

Follow these two skill files VERBATIM and in this exact order. They live at these paths in the main checkout — read them from there at the start of each phase:

  1. .claude/commands/check.md    — run quality gates inside your worktree
  2. .claude/commands/review.md   — spawn the reviewer subagent and act on pass/fail

Workflow contract:

  - Stop and report "failed at <stage>" if any of:
      * /check reports any failed gate (sidecar stays at `walked`) → stage=check
      * /review returns Fail (sidecar stays at `walked`) → stage=review

  - Success terminal state per ADR 0037: sidecar at `reviewed` for all prefixes (UX and non-UX uniformly — ADR 0018's prefix-aware fast-path is gone; the walk-skip for non-UX moved into /walk upstream).

Non-negotiables:

  - Do NOT run /build. Do NOT run /walk. Do NOT run /ship. Those are serial or done.
  - Do NOT edit MASTERPLAN.md or BUILDLOG.md. Those change only at /ship.
  - Do NOT touch other tasks' sidecars, worktrees, or branches.
  - Follow every `Never` rule in each skill file. No --no-verify, no --amend, no `git add -A`.

Your LAST message must be ONLY this JSON block (no prose before or after):

{
  "id": "<ID>",
  "status": "reviewed" | "failed",
  "stage": "check" | "review" | "done",
  "branch": "<task branch name>" | null,
  "worktree": "<worktree path>" | null,
  "notes": "<short summary, <200 chars>"
}
```

### Dispatch rules

- All wave-N agents go out in **one** assistant message with N parallel `Agent` tool calls. Do not dispatch sequentially inside a wave.
- Use `subagent_type: general-purpose` (has all tools, needed for `git worktree add`, file edits, test runs, and spawning the nested `reviewer` subagent per `/review`).
- Each subagent prompt is self-contained (the subagent cannot see this conversation).
- If `STOP_ON_FAIL` is `true` and any task in a wave returns `status: failed`, do **not** dispatch the next wave. Report and exit.

## Aggregate and report

After every wave completes (or after early stop on fail), present a single summary table to Jerry. Columns differ by phase.

### `--phase=build` summary

```
### /batch results (build phase)

| ID    | Prefix | Final status | Stage    | Notes                              |
|-------|--------|--------------|----------|-------------------------------------|
| F-6   | F-     | built        | done     | —                                   |
| BP-14 | BP-    | built        | done     | —                                   |
| LI-3  | LI-    | built        | done     | —                                   |
| SC-15 | SC-    | failed       | build    | dep=SC-14@in-progress (preflight)   |

Built (ready for /walk): F-6, BP-14, LI-3
Failed: SC-15

Suggested next steps:
  /walk F-6           # auto-skip (non-UX)
  /walk BP-14         # auto-skip (non-UX)
  /walk LI-3          # interactive walkthrough — UX
  Once all walked: /batch F-6 BP-14 LI-3 --phase=gates
```

### `--phase=gates` summary

```
### /batch results (gates phase)

| ID    | Prefix | Final status | Stage    | Notes                              |
|-------|--------|--------------|----------|-------------------------------------|
| F-6   | F-     | reviewed     | done     | —                                   |
| BP-14 | BP-    | reviewed     | done     | —                                   |
| LI-3  | LI-    | reviewed     | done     | —                                   |
| SC-15 | SC-    | failed       | check    | 2 pgTAP tests failed (see artefacts) |

Ready to ship: F-6, BP-14, LI-3
Failed (stays at `walked`): SC-15

Suggested next steps:
  /ship F-6           # serialized by .ship.lock
  /ship BP-14         # serialized — run after F-6 completes
  /ship LI-3          # serialized
  (inspect SC-15 failure — artefacts at .taskstate/artifacts/SC-15/gate-summary.json, then /check SC-15 serially to resume)
```

Do not auto-chain into `/walk`, `/ship`, or the next phase. Hand control back to Jerry.

## Known constraints / won't handle

- **`--adopt` not supported.** If a task has drift (branch/worktree on disk but sidecar says `todo`), that's a one-off — run `/build --adopt <ID>` serially, then `/batch` the rest.
- **No automatic retry.** Failed tasks stay at their last sidecar status; fix and re-run `/build --adopt <ID>` or `/check <ID>` serially.
- **No concurrent `/ship`.** `/batch` never ships. The ship lock is not touched.
- **No parallel `/walk`.** The walk gate is serial by ADR 0007 + ADR 0037 — operators run `/walk <ID>` per task between waves. For non-UX prefixes the walks auto-skip and are quick to chain manually; for UX prefixes the operator iterates per task.
- **Max 1 SC-\* per wave.** Automatically enforced by wave reshuffle. Relax only by ADR.
- **Max `--limit 5`.** Not a soft cap — rejected with a message. Relax only by ADR.

## Never

- Never dispatch more than one wave in parallel. Waves are sequential; tasks within a wave are parallel.
- Never merge two tasks into one PR. Each subagent stays on its own branch.
- Never run `/walk` or `/ship` from `/batch`. If Jerry wants automation there, it's a separate ADR.
- Never run `/check` or `/review` in `--phase=build`, and never run `/build` in `--phase=gates`. Phase boundary is strict.
- Never skip preflight for any ID. A silent skip of a missing dep is an invariant violation — reject loudly.
- Never edit `MASTERPLAN.md`, `BUILDLOG.md`, `FOLLOWUPS.md`, or another task's sidecar from the orchestrator thread. Those change only at `/ship`.
