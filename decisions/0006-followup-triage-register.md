# ADR 0006 — Follow-up triage register and `/ship` triage step

- Status: Accepted
- Date: 2026-04-19
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0005 — Parallel tasks via worktrees](0005-parallel-tasks-via-worktrees.md)

## Context

`/ship` writes a `Follow-ups:` bullet list into [BUILDLOG.md](../BUILDLOG.md) for every shipped task. The reviewer generates these bullets — non-blocking findings, deferred nits, cross-task breaks, ops notes. After 9 ships (F-1..F-9), ~20 such bullets had accumulated. Nothing read them back.

Consequences observed before this ADR:

1. F-6's review flagged a cross-task break with F-7; it sat in BUILDLOG prose for a day until a human noticed and promoted it manually as F-7a.
2. F-8's `exceptions_to_handle` follow-up would have silently gated every AG-\* task if not caught by the F-10/F-11/F-12 manual sweep.
3. No audit trail: "was this follow-up ever addressed?" required grepping BUILDLOG and guessing from commit messages.

The ritual (`/plan-next → /build → /check → /review → /ship`) had no step that closes the loop on follow-ups.

## Decision

Add a triage step to the ritual. Three concrete changes:

### 1. `FOLLOWUPS.md` — append-only disposition register

Every follow-up gets exactly one row in a markdown table. Four dispositions:

- `promoted` — became a new MASTERPLAN row + `.taskstate/<NEW-ID>.json`.
- `folded` — absorbed into an existing task's acceptance criteria. Target task ID recorded.
- `dropped` — nit; fix opportunistically. Reason recorded.
- `resolved` — already done by a later shipped task. Resolver task ID recorded.

The register is the audit trail. It does not replace BUILDLOG's prose follow-ups — those stay verbatim as the source record. FOLLOWUPS.md records decisions, not findings.

### 2. `/ship` Step 7.5 — triage before worktree cleanup

Between BUILDLOG append and worktree cleanup, before releasing `.ship.lock`:

1. Re-read the `Follow-ups:` block just written.
2. For each bullet, prompt the shipper: `Promote / Fold / Drop / Resolved`.
3. On **Promote**: ask for new ID (suggest next free in chosen phase), subject, deps, PRD refs. Grep MASTERPLAN for the proposed ID — fail loud if it collides. Append row to the correct Phase table. Create `.taskstate/<NEW-ID>.json` with `status: todo`. Log in FOLLOWUPS.md.
4. On **Fold / Drop / Resolved**: log in FOLLOWUPS.md only, with the target task ID or reason.
5. All decisions land in the same `chore: ship <ID>` commit. No separate commit.

Empty follow-ups block → no prompt, fast path.

### 3. `/plan-next` drift gate

Before returning eligible tasks, diff every `Follow-ups:` bullet in BUILDLOG against every row in FOLLOWUPS.md. Unregistered bullets surface a warning block above the eligible list, with a suggested `/triage <ID>` command.

This catches historical drift (pre-ADR-0006 ships) and any ship that bypassed triage.

### 4. `/triage <ID>` — standalone command

Idempotent. Walks BUILDLOG for one task's follow-ups, reconciles against FOLLOWUPS.md, prompts for any missing disposition. `/triage --all` backfills every shipped task — runs once to close out pre-ADR-0006 history.

## Rules

- **Human decides.** Promote vs drop requires judgment about PRD context and deployment timeline. No auto-promotion.
- **ID collision check is non-negotiable.** Before any append to MASTERPLAN, grep for the proposed ID. Two parallel ships promoting under the lock is the risk; the grep is the guard.
- **One register, append-only.** Never edit FOLLOWUPS.md rows retroactively. If a disposition was wrong, add a new row with `corrects: <earlier row>` and explain.
- **Bundling is allowed.** Two bullets from the same (or related) source tasks may promote to a single new ID if they ship together cleanly. F-10 bundled two F-8 follow-ups; F-11 bundled four from F-6/F-7. The register records both bullets pointing at the same target ID.
- **Chore, not task.** Promoted follow-ups get MASTERPLAN rows; the triage mechanism itself is meta-workflow and does not get a MASTERPLAN row.

## Consequences

### Positive

- Follow-ups cannot silently rot. The drift gate in `/plan-next` is a hard signal.
- Audit trail is grep-able: `grep "F-8" FOLLOWUPS.md` returns every follow-up ever spawned by F-8 and its fate.
- Bundling stays human-controlled, preserving the 1:1 task-to-PR spirit.
- Promoted rows appear in MASTERPLAN automatically — no manual "don't forget to add F-10" step.

### Negative

- `/ship` gains an interactive prompt in the common case. Acceptable cost; follow-ups average ~2 per ship.
- Two registers to maintain (BUILDLOG prose + FOLLOWUPS.md rows). Intentional: prose for context, register for state.
- Parallel ships can race on MASTERPLAN row appends. Mitigated by `.ship.lock` (ship is already serialized). Triage runs inside the lock.

### Backfill

One-shot `/triage --all` on ADR adoption registers every historical follow-up from F-1..F-9. The earlier manual triage (which produced F-10/F-11/F-12) is the source of truth for that backfill; paste those decisions in.

## Alternatives considered

- **Hook-driven auto-promotion.** Rejected. Hooks run silently; promotion requires judgment.
- **YAML-structured follow-ups in BUILDLOG.** Rejected. Over-engineering for ~2 bullets per ship; prose is readable and the register supplies structure.
- **Register columns inside MASTERPLAN.md.** Rejected. MASTERPLAN's fixed columns (ID/Task/Deps/PRD) don't fit disposition metadata; mixing them would bloat every diff.
- **LLM-assisted triage (`/triage --propose`).** Deferred. Worth revisiting after ~20 more follow-ups have gone through the manual pipeline to amortize design cost.

## References

- [BUILDLOG.md](../BUILDLOG.md) — source of follow-up bullets.
- [MASTERPLAN.md](../MASTERPLAN.md) — target of promoted rows.
- [.claude/commands/ship.md](../.claude/commands/ship.md) — triage step implementation.
- [.claude/commands/plan-next.md](../.claude/commands/plan-next.md) — drift gate.
- [.claude/commands/triage.md](../.claude/commands/triage.md) — standalone triage command.
- [FOLLOWUPS.md](../FOLLOWUPS.md) — register.
