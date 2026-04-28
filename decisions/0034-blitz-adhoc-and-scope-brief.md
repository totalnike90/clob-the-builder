# ADR 0034 — `/blitz` ad-hoc trailers + init scope brief

- Status: Accepted
- Date: 2026-04-25
- Deciders: Jerry Neo (PM/owner)
- Extends: [ADR 0032 — `/blitz` session-level ritual bypass](0032-blitz-fast-path.md)

## Context

ADR 0032 shipped `/blitz` as a session-level fast-path, but constrained the trailer-driven discovery to **task IDs that already exist in MASTERPLAN with eligible sidecar status**. Two practical gaps surfaced once the command was in regular use:

1. **No legal path for ad-hoc work.** Operator iterating against the dev server frequently spots work that doesn't yet have a MASTERPLAN row — a small new component, a PRD-prose gap, a refactor that emerged from the iteration itself. Current `/blitz` rejects any commit whose `Task: <ID>` trailer doesn't resolve to an existing eligible row, forcing the operator to either (a) abort blitz, hand-edit MASTERPLAN, restart, or (b) overload an unrelated task ID — both leak scope and corrupt the audit trail.
2. **Reconciliation is post-hoc only.** Step 4 (Scope reconciliation) catches drift between implementation and MASTERPLAN/PRD at _land_, after the iteration is done. Operator can't see overlap with existing tasks before they spend an hour rebuilding something LI-09 already covers, and PRD updates surface only as drift remediation, not as first-class declarable scope.

The reconciliation gap also obscures planning when a session genuinely surfaces new scope. The Step 4.7.iii "new MASTERPLAN row" sub-prompt exists, but it fires once per task at land — never _between_ tasks, and never _before_ the operator commits to a direction.

## Decision

Two additive changes to `/blitz`. Both preserve the 1:1 task/revert invariant and the existing "no auto-apply" discipline.

### A. Ad-hoc trailer convention — `Task: NEW-<slug>`

Operator may use `Task: NEW-<slug>` (kebab-case slug, operator-chosen) on any granular commit during a blitz session to mark work that doesn't yet have a MASTERPLAN row. Multiple distinct slugs per session are allowed; commits sharing a slug roll up into the same resolution at land.

**Phase 2 — trailer scan.** Step 1 accepts `NEW-*` trailers as legal task IDs alongside existing MASTERPLAN IDs. They appear in `TASK_COMMITS` keyed by the slug.

**Phase 2 — preflight.** Step 2 skips the MASTERPLAN-row check, sidecar-status check, and Deps check for `NEW-*` IDs. The risky-surface gate (Step 3) and cheap gates (Step 5) still apply unchanged.

**Phase 2 — resolution at reconciliation.** Step 4 enters a forced-resolution sub-flow for each `NEW-*` ID. Operator picks one of three:

- **Promote** — supply phase / new MASTERPLAN ID / subject / Deps / PRD refs (same field set as Step 4.7.iii). The new ID replaces the `NEW-<slug>` trailer in the squash commit and gets a fresh sidecar with `status: blitzed` at land.
- **Fold** — supply an existing MASTERPLAN ID (any non-terminal sidecar status). The `NEW-<slug>` commits get bucketed into that ID's `TASK_COMMITS` entry; the squash trailer becomes the existing ID; that ID's sidecar flips to `blitzed`.
- **Abort** — `/blitz` halts the entire session (no partial ship). Operator either drops the `NEW-*` commits via `git rebase -i` and re-runs, or accepts that the work doesn't ship in this session.

The resolution is staged in `_blitz.json.staged_edits` like other reconciliation entries, so a later cheap-gate failure doesn't lose the operator's work.

**Phase 2 — squash sequence.** Step 9 uses the resolved ID for the squash commit subject and trailer. The `NEW-<slug>` placeholder never appears on `main`.

**BUILDLOG.** The session entry's per-task sub-block uses the resolved ID. A `Resolved from: NEW-<slug>` line is added to the sub-block when the trailer was ad-hoc, so the audit trail shows the work originated as ad-hoc rather than against a pre-existing row.

### B. Optional init scope brief

**Phase 1 init** adds an optional intent prompt after the slug:

```
Describe what you intend to build this session (blank to skip):
```

If operator types intent, `/blitz` runs a deconfliction brief:

1. Tokenize intent into keywords (lowercase, drop stopwords).
2. Grep `MASTERPLAN.md` for top-N rows (default 5) matching any keyword in the subject column.
3. Grep `../specs/SALLY-PRD-Tech-Spec.md` for top-N section headers (default 5) matching any keyword.
4. Print briefing:

   ```
   Scope brief: "<intent>"

   Existing MP rows that may overlap:
     - <ID> — <subject> (<status>)
     - ...

   PRD sections referenced:
     - §X.Y <header> — <stub | non-stub>
     - ...

   Suggested paths:
     - Extend <ID> if scope is purely additive
     - Fold into <ID> for related UX
     - Or: proceed as NEW-<slug> if genuinely new
   ```

The brief is informational only — no edits, no gates, no sidecar mutations. Operator reads it, decides, proceeds. Brief is best-effort grep, not a structured planner; when intent is vague the brief surfaces noise and operator ignores it. Blank intent skips the brief entirely (preserves ADR 0032's "no friction at init" intent).

The intent string and brief output (if generated) are persisted in `_blitz.json.intent` and `_blitz.json.scope_brief` so they appear in the bundled BUILDLOG session entry's preamble.

### C. PRD edits as first-class declarable

No mechanism change — Step 4.7.ii (`open §X / open §Y / N`) already supports PRD `$EDITOR` sessions at land. The change is **documentation**: Phase 1 brief now explicitly states that PRD edits are legal as part of any task's commits during the session, and reconciliation will surface them at land. The previously-implicit pathway is made explicit so operators don't believe PRD changes require dropping back to `/build` + `/ship`.

## Consequences

- **(a) Ad-hoc work is auditable.** `NEW-<slug>` placeholders never reach `main` — every blitz squash carries either a real MASTERPLAN ID or aborts. The `Resolved from:` BUILDLOG line preserves the ad-hoc origin without polluting `git log`.
- **(b) 1:1 task/revert invariant preserved.** Resolution is deterministic per slug → one squash commit per resolved ID. Folded `NEW-*` commits inherit the existing ID's revert path.
- **(c) `Deps` graph integrity preserved.** Promoted `NEW-*` rows can declare `Deps`; folded `NEW-*` commits inherit the existing row's `Deps` (no new dep edges introduced silently).
- **(d) Init scope brief is opt-in.** Blank intent → no grep, no brief, no token cost. The brief is cheap when used (two greps, ~100 LOC of output).
- **(e) Brief is best-effort, not authoritative.** Keyword-grep is the simplest implementation that catches the obvious overlaps; complex semantic overlaps remain the operator's judgment call. We don't promise correctness — we promise visibility.
- **(f) PRD edits remain operator-typed.** Despite being "first-class," PRD prose is still operator-authored via `$EDITOR`. ADR 0032 consequence (g) ("No auto-generated PRD prose") is preserved.
- **(g) MASTERPLAN row creation still goes through reconciliation.** No way to fabricate rows mid-session — `NEW-<slug>` is just a placeholder; the actual MASTERPLAN edit happens in Step 4 with the same operator-prompt discipline as existing 4.7.iii.
- **(h) Phase 2 retry safety extended.** `_blitz.json.staged_edits` now also keys ad-hoc resolutions, so re-entering Phase 2 after a cheap-gate failure preserves the resolution choices.

## Alternatives considered

- **Generic `Task: ADHOC` (single bucket).** Collapses all ad-hoc commits in a session into one resolution — too coarse when a session surfaces two unrelated pieces of new work. Rejected for `NEW-<slug>` per-piece granularity.
- **Auto-promote `NEW-*` to MASTERPLAN row at land (no operator choice).** Loses the fold path (which is often what the operator actually wants — work is adjacent to an existing row, not new scope). Rejected.
- **Pre-build deconfliction as a hard gate (refuse session if overlap detected).** Too restrictive — overlap is often intentional (you _want_ to extend LI-09). Rejected for informational-brief.
- **Mid-session `/blitz plan "<intent>"` re-brief command.** Useful but adds parser surface to `$ARGUMENTS` and a third phase to detect. Defer to a future ADR if operators ask for it; init-only brief covers the stated need.
- **Semantic embedding-based overlap detection.** Higher quality match, but adds infra (embedding endpoint or local model) and latency. Brief is meant to be cheap and fast. Rejected for keyword-grep.
- **Force ad-hoc resolution at _init_ rather than land.** Defeats the point — operator often discovers ad-hoc work mid-session and wouldn't know to declare it upfront. Rejected.
- **Allow `NEW-*` trailers in `/build` / `/ship`.** Out of scope — those rituals require pre-committed scope; their preflight is the gate. ADR 0034 stays scoped to `/blitz` only. Rejected.

## Non-goals

- Not a way to bypass MASTERPLAN — every shipped commit still resolves to a real MASTERPLAN row.
- Not a planner — the scope brief is a grep-based reading aid, not a structured task decomposition.
- Not a PRD authoring assistant — PRD edits remain operator-typed, ADR 0032 consequence (g) preserved.
- Not retroactive — sessions started before this ADR continue under ADR 0032 semantics; this only applies to new `/blitz` invocations.

## Revert

Strip the `NEW-*` acceptance from Step 1 trailer scan, restore the unconditional MASTERPLAN-row check in Step 2, remove the resolution sub-flow from Step 4, drop the optional intent prompt from Phase 1, and remove the `intent` / `scope_brief` keys from `_blitz.json`. Any in-flight blitz session with `NEW-*` commits must be either folded manually or aborted before the revert lands. CLAUDE.md `/blitz` paragraph reverts to its ADR 0032 wording.
