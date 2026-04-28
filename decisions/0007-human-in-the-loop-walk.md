# ADR 0007 — Human-in-the-loop walkthrough between /review and /ship

- Status: Accepted (amended by [ADR 0037](0037-walk-before-gates-iterative.md) — `/walk` repositioned to immediately after `/build`, before `/check` + `/review`; the human-in-the-loop principle and prefix matrix are unchanged)
- Date: 2026-04-19
- Deciders: Jerry Neo (PM/owner)
- Supersedes parts of: —
- Extends: [ADR 0005 — Parallel tasks via worktrees + sidecars](0005-parallel-tasks-via-worktrees.md), [ADR 0002 — Branch-per-task + squash merge](0002-branch-per-task-squash-merge.md)
- Amended by: [ADR 0037 — Reorder `/walk` to immediately after `/build`](0037-walk-before-gates-iterative.md)

## Context

The v2 ritual (`/plan-next → /build → /check → /review → /ship`) has no step where a human exercises the product. Every gate is automated or agent-driven:

- `/check` runs lint, typecheck, tests, build, and for LI-\*/CH-\* a Playwright screenshot.
- `/review` dispatches a blinded reviewer subagent that reads the diff.
- `/ship` squashes, merges, updates BUILDLOG.

For SALLY specifically, two classes of failure cannot be caught by any of the above:

1. **Design-system and voice drift on user-facing surfaces (LI-\*, CH-\*).** Playwright asserts structural match; it does not tell us whether the copy reads as SALLY's voice, whether the emoji cadence is right, whether the pink/fluff balance feels correct, or whether the flow "feels women-first." A hex drift from `#8B5CF6` to `#8B5BFE` can pass structural diff.
2. **Adversarial agent behavior (AG-\*).** §9.3 (buyer identity isolation) and §9.4 (offline transaction block) are non-negotiable rules the agent must enforce even under seller prompt-injection or buyer social engineering. A single synthetic test message in `/check` is not adversarial coverage; real probing requires a human trying to break the agent.

A secondary gap — `/review` was also light on security and code-quality depth. The ritual had no explicit `security-reviewer` trigger for AU-\*/AG-\*/payment tasks, no coverage assertion at review time, and no function/file-size checks despite those being in the global `~/.claude/rules/code-review.md`.

## Decision

### 1. Introduce `/walk <ID>` as a required gate between `/review` and `/ship`

New sidecar status sequence: `todo → in-progress → built → reviewed → walked → shipped`.

- `/walk` is **mandatory** for task prefixes **LI-\***, **CH-\***, **AG-\***, **AU-\***.
- For other prefixes (F-\*, SC-\*), `/walk` is a **no-op flip-through** — the sidecar moves `reviewed → walked` with a `walk_notes` entry of `{ step: "n/a — non-user-facing", result: "skip", … }`. The ritual still runs so `/ship` has a uniform precondition (`status: walked`) with no branching.
- `/walk` runs **from inside the task's worktree** so the dev server exercises the task's branch, not `main`.
- `/walk` reads the user-story IDs from the PRD refs, maps them to steps in `../docs/SALLY-User-Journeys.md`, prints a numbered checklist, and waits for Jerry's pass/fail/skip notes.
- For AG-\*, the checklist appends **adversarial probes** derived from §9.3 and §9.4 verbatim (offline-request block, identity-reveal refusal, seller prompt-injection resistance).

Results persist in `.taskstate/<ID>.json` under a new `walk_notes` array (one object per step, preserving attempt history across re-runs). `/ship` copies this array verbatim into the BUILDLOG entry so the durable human-judgment trail is greppable forever.

### 2. Tighten `/review` in parallel (not a separate gate)

- **Parallel `security-reviewer` dispatch** for AU-\*, AG-\*, payment code, RLS changes, or JWT handling. Same message, same cost window as the primary reviewer. Any CRITICAL finding → Fail.
- **Attach `/check`-emitted artifacts to the reviewer prompt**: `.taskstate/artifacts/<ID>/coverage.json` for the coverage number, `screenshots/` for LI-\*/CH-\* visual comparison.
- **Expanded prompt checklist** — voice & copy as a first-class item (separate from design system), code quality (function LOC, file LOC, nesting, error handling, no debug prints), coverage threshold awareness.

### 3. `/check` emits machine-readable artifacts

Under `.taskstate/artifacts/<ID>/` (gitignored):

- `coverage.json` — merged summary, `{ lines_pct, per_package }`.
- `screenshots/` — mobile-viewport PNGs for LI-\*/CH-\*.
- `gate-summary.json` — each gate with pass/fail/skip.

This lets `/review` and `/walk` consume gate output without re-running, and gives future tooling a stable surface.

## Consequences

### Positive

- UX, voice, and adversarial agent failures get human eyes before hitting `main`.
- BUILDLOG accumulates a durable record of which shipped tasks had "felt off" moments — future-you can grep for patterns.
- Security/code-quality gaps in `/review` closed without adding a new ritual stage (parallel dispatch, same prompt window).
- Gate artifacts flow forward instead of being re-derived.

### Negative

- Every user-facing task now requires Jerry's synchronous attention before ship. For a 4-week MVP with 85 tasks, that adds up — LI-\*/CH-\*/AG-\*/AU- span most of the active work. Budget roughly 3–10 minutes per task for the walkthrough; AG-\* adversarial probes are the slowest.
- Non-user-facing tasks (F-\*, SC-\*) still run through `/walk` as a no-op flip-through, which is one extra command call. The alternative (branching in `/ship`) was rejected to keep the precondition uniform.
- `.taskstate/artifacts/` is a new gitignored directory; developers must know it exists for debugging. Mitigation: `/check`'s output prints the artifact path.

### Migration

- All in-flight tasks currently at `status: reviewed` can flip to `walked` via one `/walk` call.
- Shipped tasks are not re-walked. The policy applies from 2026-04-19 forward.

## Alternatives considered

1. **Post-ship walkthrough with automatic revert.** Rejected — `main` is the shared trunk; reverting after `/ship` pollutes history and reacts to issues instead of preventing them.
2. **Require `/walk` only for user-facing prefixes; branch `/ship`.** Rejected — branching the precondition makes the ritual harder to reason about. A no-op `/walk` for F-\*/SC-\* is a smaller cognitive tax than a conditional status check in `/ship`.
3. **Roll the human pass into `/review` itself.** Rejected — the reviewer subagent is intentionally blinded from the build chat and runs remotely. Mixing human steps into its prompt would dilute the independent-review property (ADR 0005 rationale).
4. **Heavier BUILDLOG UX report at ship time.** Rejected on its own as insufficient (catches problems after ship), but adopted as a complementary output of `/walk` via the `walk_notes` section.

## Files changed by this ADR

- [.claude/commands/walk.md](../.claude/commands/walk.md) — new command.
- [.claude/commands/review.md](../.claude/commands/review.md) — parallel `security-reviewer`, screenshot + coverage attach, expanded checklist, next-step hint points at `/walk` for user-facing prefixes.
- [.claude/commands/check.md](../.claude/commands/check.md) — emit `coverage.json`, `screenshots/`, `gate-summary.json` under `.taskstate/artifacts/<ID>/`.
- [.claude/commands/ship.md](../.claude/commands/ship.md) — require `status: walked`; copy `walk_notes` into BUILDLOG entry.
- `.taskstate/<ID>.json` schema — add `walk_notes: Array<{ step, result, note, attempt?, at? }>`.
- `CLAUDE.md` — update the ritual line to include `/walk`.
