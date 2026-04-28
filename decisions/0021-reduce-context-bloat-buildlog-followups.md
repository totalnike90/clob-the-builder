# ADR 0021 — Reduce context bloat from MASTERPLAN / BUILDLOG / FOLLOWUPS

- Status: Accepted
- Date: 2026-04-21
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0006 — Follow-up triage register](0006-followup-triage-register.md), [ADR 0017 — Split build-process tasks into Phase BP](0017-split-build-process-into-phase-bp.md)

## Context

Three files grow unboundedly as the project ships tasks and are pulled into context by nearly every ritual invocation:

| File          | Lines | Chars   | ~Tokens     | Growth per ship                                           |
| ------------- | ----- | ------- | ----------- | --------------------------------------------------------- |
| MASTERPLAN.md | 241   | 32,073  | ~8,000      | ~3 lines (1 status column update + ~half a row amortised) |
| BUILDLOG.md   | 834   | 134,920 | ~33,700     | ~50 lines / ~1,300 tokens                                 |
| FOLLOWUPS.md  | 157   | 83,706  | ~20,900     | ~1–3 rows / ~300 tokens                                   |
| **Combined**  | 1,232 | 250,699 | **~62,700** | —                                                         |

At 33 tasks shipped (2026-04-21 snapshot) the three files already sit at ~63K tokens combined. MVP target is ~131 rows (4× today). BUILDLOG alone projects to ~120K tokens at that scale — larger than most task PRD sections.

Who reads what today:

| Command                                   | MASTERPLAN | BUILDLOG                | FOLLOWUPS                                   | Sidecar |
| ----------------------------------------- | ---------- | ----------------------- | ------------------------------------------- | ------- |
| /plan-next                                | full       | full (grep Follow-ups:) | full (fuzzy match against BUILDLOG bullets) | all     |
| /build                                    | 1 row      | —                       | —                                           | 1 file  |
| /check                                    | —          | —                       | —                                           | 1 file  |
| /review                                   | —          | —                       | —                                           | 1 file  |
| /walk                                     | —          | —                       | —                                           | 1 file  |
| /ship                                     | 1 row      | append                  | append                                      | 1 file  |
| /triage                                   | scan       | full awk                | full scan                                   | all     |
| CLAUDE.md §"Before anything else" mandate | full       | —                       | —                                           | —       |

`/build`, `/check`, `/review`, `/walk` are already task-scoped via `.taskstate/<ID>.json`. The hot spots that load whole files are **/plan-next**, **/triage**, and **CLAUDE.md's "read MASTERPLAN first" directive** at session start.

Two structural facts make this fixable without rewriting history:

1. The sidecar split (ADR 0002 / ADR 0005) already proves chunking works. `.taskstate/<ID>.json` is the canonical per-task state; `scripts/sync-masterplan-status.py` derives the Status column from sidecars. Per-task state lives at O(1) cost.
2. BUILDLOG's prose format has no per-task boundary markers today (only `^## YYYY-MM-DD` headers). Extracting one task's block requires guessing the end (next `^## ` or EOF) — forcing whole-file reads in `/triage` and `/plan-next`.

## Decision

Two independently adoptable layers. Adopt both as BP-12.

### Layer 1 — Anchor every BUILDLOG entry with stable markers

Wrap each entry in HTML comment markers:

```markdown
<!-- TASK:SC-7:START -->

## 2026-04-21 17:28 SGT — SC-7 invite_codes table

…

<!-- TASK:SC-7:END -->
```

- **Backfill:** one-shot `scripts/backfill-buildlog-anchors.py` wraps existing shipped entries by matching `^## [0-9]{4}-.*— <ID>` headers and closing at the next header (or `<!-- Newest on top -->` sentinel for the final block). Idempotent; safe to re-run.
- **Forward:** `/ship` emits both markers when appending a new entry.
- **Slice helper:** `scripts/slice-buildlog.py <ID>` prints the marker-delimited block for one task. O(1) grep instead of O(file) awk.
- **Consumers:** `/triage <ID>` and any future "show me the prose for X" flow read via slice-buildlog rather than scanning.

### Layer 2 — Sidecar becomes the follow-ups source-of-truth

Today: follow-ups live in BUILDLOG prose; FOLLOWUPS.md is an independently-edited register; the two are kept in sync by Step 7.5 (ADR 0006) and `/triage`. This forces `/plan-next` to read both files just to answer "are there any follow-ups needing action?".

Change:

- `.taskstate/<ID>.json` gains a `follow_ups: []` array. Each entry: `{ text, disposition, target_id?, note?, resolved_at? }`.
- `/ship` Step 7.5 writes dispositions into the originating sidecar at the same moment it writes FOLLOWUPS.md rows and BUILDLOG prose. Three writes, one truth.
- **FOLLOWUPS.md becomes fully generated.** `scripts/regen-followups.py` rebuilds it from sidecars. Header declares it a derived artifact; no hand edits. Regen runs inside `/ship` and `/triage`.
- `/plan-next` no longer reads BUILDLOG or FOLLOWUPS at all. Follow-up state comes from sidecars (N small JSON files).
- `/triage` reads sidecars for disposition state; slice-buildlog only for prose context display.

Cost after adoption: `/plan-next` reads ~N × ~250-byte sidecars ≈ 8 KB / ~2 K tokens at 130 tasks, vs. ~54 K tokens today for BUILDLOG + FOLLOWUPS combined.

### CLAUDE.md softening

`CLAUDE.md` §"Before anything else" currently says "Read `MASTERPLAN.md` — it is the single source of truth for work." This forces 8 K tokens at session start regardless of the task. Rewrite to:

> MASTERPLAN.md is the index. For a specific task, read the sidecar `.taskstate/<ID>.json` and the PRD section referenced there. Load MASTERPLAN fully only when surveying eligible work (`/plan-next`).

### Layer 3 — deferred

Archiving old BUILDLOG entries into `BUILDLOG-archive/YYYY-MM.md` is the natural follow-on but is **not** in scope for BP-12. Revisit when hot BUILDLOG crosses ~60 entries or ~1,500 lines.

## Consequences

### Positive

- `/plan-next` token cost drops from ~63 K to ~10 K (MASTERPLAN row subset + sidecars). ≥50% target.
- `/triage` token cost drops: sidecar reads replace full BUILDLOG + FOLLOWUPS scans; slice-buildlog loads one task's prose on demand. ≥40% target.
- Session-start cost drops by ~8 K tokens once CLAUDE.md is softened.
- FOLLOWUPS.md as a pure view eliminates a whole class of drift (hand-edited register can disagree with the BUILDLOG-derived one — ADR 0006 Step 7.5 exists specifically to counter this).
- Anchored BUILDLOG enables future tooling (per-task revert-command extraction, per-task PR body assembly) without ad-hoc boundary heuristics.

### Negative

- One-shot BUILDLOG backfill rewrites 33 shipped entries' surrounding bytes (anchors added, prose unchanged). Diff is audit-verifiable but touches the full file in a single commit.
- Sidecar schema grows. Older sidecars (pre-BP-12) will lack `follow_ups` — readers must treat absence as empty array.
- `/ship` Step 7.5 now writes three places instead of two (prose + FOLLOWUPS + sidecar). More IO per ship; negligible.
- Moving FOLLOWUPS.md to generated status removes ability to hand-edit. Acceptable per user decision (see Implementation note).

### Neutral

- ADR 0006 invariant preserved: every BUILDLOG follow-up bullet has a disposition inside the ship commit. Just lands in one more place (sidecar).
- ADR 0002's 1:1 task→branch→PR→squash preserved. BP-12 is its own row/branch/PR/squash.
- BUILDLOG prose format unchanged. Anchors are HTML comments — invisible in rendered markdown, stable under human editing.
- `sync-masterplan-status.py` unaffected. It already reads sidecars.

## Implementation note

Implementation deferred to **BP-12** via `/build`. This ADR only adopts the decision + creates the MASTERPLAN row (already landed in `chore: ship SC-7`) + sidecar atomically (per ADR 0017 precedent).

Confirmed with owner 2026-04-21:

- Scope: Layer 1 + Layer 2; Layer 3 deferred.
- FOLLOWUPS.md becomes fully generated (no hand edits).
- Ships as a normal BP-\* task through the full ritual (branch, PR, /review, /walk fast-path via BP-5, /ship).
