---
description: Reconcile a shipped task's BUILDLOG follow-ups against FOLLOWUPS.md and apply dispositions. Usage — /triage <TASK-ID> | /triage --all
argument-hint: <TASK-ID | --all>
---

You are triaging the follow-ups of task **$ARGUMENTS** under workflow v2 + [ADR 0006](../../decisions/0006-followup-triage-register.md) + [ADR 0021](../../decisions/0021-reduce-context-bloat-buildlog-followups.md). Goal: every `Follow-ups:` bullet in `BUILDLOG.md` gets exactly one entry in the originating sidecar's `follow_ups[]`, and every `promoted` disposition creates a real MASTERPLAN row + sidecar. `FOLLOWUPS.md` is regenerated from sidecars by `scripts/regen-followups.py` — derived artifact, never hand-edited.

**Idempotent** — running twice on the same ID is safe; it only prompts for bullets not yet registered.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Modes

- `/triage <TASK-ID>` — reconcile one shipped task's follow-ups.
- `/triage --all` — backfill; walks every shipped entry in BUILDLOG, triages each in turn.

## Preflight — must run on `main` in the main checkout

1. `git worktree list --porcelain | awk '/^worktree/ {print $2; exit}'` — confirm `pwd` equals the main checkout.
2. `git branch --show-current` must be `main`.
3. `git status` must be clean.

Triage is a chore, not a task: no branch, no worktree, no sidecar for itself. Edits land on `main` in a single `chore: triage <ID>` (or `chore: triage backfill`) commit.

## Steps

### 1. Slice BUILDLOG for the target task(s)

```bash
python3 scripts/slice-buildlog.py $ARGUMENTS
```

The block is delimited by `<!-- TASK:<ID>:START -->` / `<!-- TASK:<ID>:END -->` anchors added by `/ship` (per [ADR 0021](../../decisions/0021-reduce-context-bloat-buildlog-followups.md)). Non-zero exit → block missing anchors → run `python3 scripts/backfill-buildlog-anchors.py` first.

Extract every bullet under `Follow-ups:` until the list ends. Normalize to a short single-line description (strip markdown, collapse whitespace).

Empty or `none` → "Nothing to triage" and exit.

For `--all`: iterate every anchored block (`grep -oE '^<!-- TASK:[A-Z]+-[0-9a-z]+:START -->' BUILDLOG.md`) and run the single-task flow for each in order (oldest first, so newer dispositions can reference already-registered source tasks).

### 2. Diff against the source sidecar's `follow_ups[]`

For each bullet, read `.taskstate/<SOURCE>.json` and check `follow_ups[]` for a matching entry. Fuzzy match (substring of `entry.text` vs the normalized bullet, case-insensitive) — don't require byte-identical paraphrases.

Build the **unregistered set** — bullets with no sidecar entry. Empty → "All follow-ups for $ARGUMENTS are registered" and exit.

### 3. Prompt for disposition

List all unregistered bullets and offer a batch option first:

```
Follow-ups for <ID>: <N> unregistered bullets.

  1. "<bullet 1 paraphrase>"
  2. "<bullet 2 paraphrase>"
  ...
  N. "<bullet N paraphrase>"

Batch disposition? (Enter = handle per-bullet)
  A. Drop all       — reason: ______________
  B. Promote all    — bundle into a single new task
  C. Fold all       — into existing task <ID>
  D. Resolved all   — by shipped task <ID>
```

**A. Drop all.** Prompt once for a reason string (required, non-empty). Append N `follow_ups[]` entries, all `disposition: "dropped"`, same `note: <reason>`. No MASTERPLAN edit.

**B. Promote all — bundle.** Prompt once: phase / new ID / subject / deps / PRD refs (same questions as single Promote, same ID-collision check). Append one MASTERPLAN row + one sidecar. Append N entries, all `disposition: "promoted"`, same `target: <NEW-ID>`.

**C. Fold all.** Prompt once for target task ID (must exist in MASTERPLAN). Append N entries, all `disposition: "folded"`, same `target: <TARGET-ID>`. No MASTERPLAN edit.

**D. Resolved all.** Prompt once for resolver task ID (must appear as `^<!-- TASK:<ID>:START -->` in BUILDLOG). Append N entries, all `disposition: "resolved"`, same `target: <RESOLVER-ID>`.

**Enter / `n`.** Fall through to per-bullet prompts below.

For each unregistered bullet (per-bullet path):

```
Source: <SOURCE-ID>
Bullet: "<bullet text verbatim>"

Disposition?
  1. Promote   — new MASTERPLAN row + sidecar
  2. Fold      — absorb into an existing task's acceptance criteria
  3. Drop      — nit; fix opportunistically
  4. Resolved  — already done by a later shipped task
```

### 4. Apply the disposition

#### Promote

1. Ask: **"Target phase?"** (any prefix listed in `prefixes:` in `ritual.config.yaml`). Default to the source task's phase.
2. Read MASTERPLAN.md's Phase table. Compute next free ID (max existing numeric suffix in the phase + 1, or ask for an explicit `<N>a` variant).
3. **ID collision check (required).** `grep -E "^\| <NEW-ID> " MASTERPLAN.md` — must return zero. On match, abort this bullet, report, re-prompt.
4. Ask: **"Subject?"** (follows existing phase's style).
5. Ask: **"Deps?"** (comma-separated IDs).
6. Ask: **"PRD refs?"**. Default to source task's PRD refs.
7. Append a row to the correct Phase table in MASTERPLAN.md. Match existing row formatting (pipe-padded markdown).
8. Create `.taskstate/<NEW-ID>.json`:
   ```json
   {
     "id": "<NEW-ID>",
     "status": "todo",
     "branch": null,
     "worktree": null,
     "pr": null,
     "commit": null,
     "updated_at": "<ISO-timestamp>"
   }
   ```
9. Append to `.taskstate/<SOURCE>.json`'s `follow_ups[]`: `{ text, disposition: "promoted", target: "<NEW-ID>", note: null, decided: "<today>" }`.

**Bundling:** if the next unregistered bullet is plausibly the same task, offer _"Bundle into <NEW-ID>? (y/n)"_. On yes, append another sidecar entry with the same `target`; do not create a second MASTERPLAN row or sidecar.

#### Fold

1. Ask: **"Target task ID?"** (existing row in MASTERPLAN, planned or shipped).
2. Verify: `grep -E "^\| <TARGET-ID> " MASTERPLAN.md` ≥1 match.
3. Append `{ text, disposition: "folded", target: "<TARGET-ID>", note: null, decided }`.

No MASTERPLAN edit. No new sidecar. The target task owner honors the folded follow-up during its own `/build`.

#### Drop

1. Ask: **"Reason? (one line)"**.
2. Append `{ text, disposition: "dropped", target: null, note: "<reason>", decided }`.

#### Resolved

1. Ask: **"Resolver task ID?"**.
2. Verify in BUILDLOG: `grep -E "^<!-- TASK:<RESOLVER-ID>:START -->" BUILDLOG.md` must match (anchor, not header).
3. Optional: ask for a line ref (e.g. `path/to/file.ext:48`) — included in `note`.
4. Append `{ text, disposition: "resolved", target: "<RESOLVER-ID>", note: "<optional-ref>" | null, decided }`.

### 5. Regenerate and commit

```bash
python3 scripts/regen-followups.py
git add MASTERPLAN.md FOLLOWUPS.md .taskstate/
git commit -m "chore: triage $ARGUMENTS"
```

`chore:` prefix, no task trailer (triage is not a MASTERPLAN task). `--all` mode → `chore: triage backfill` and the body lists source IDs covered.

Do not push automatically — the next `/ship` will push, or the user can `git push` when ready.

### 6. Report

```
### Triaged — $ARGUMENTS

- Bullets triaged: <n>
  - Promoted: <list of new IDs>
  - Folded: <list of target IDs>
  - Dropped: <count>
  - Resolved: <list of resolver IDs>
- MASTERPLAN rows added: <count>
- Sidecars created: <count>
- FOLLOWUPS.md rows added: <n>

Commit: <sha>

Next: `/plan-next` will now see the new eligible tasks (promoted IDs with status `todo`).
```

## Never

- Never auto-promote. Every disposition needs an explicit human choice. A single `y` to accept a suggestion is fine, but the prompt must appear.
- Never skip the ID-collision check before appending — two triage runs under concurrent ships can race; the grep is the guard.
- Never edit historical sidecar `follow_ups[]` entries retroactively. Wrong disposition → append a new entry referencing the earlier one in `note`.
- Never hand-edit `FOLLOWUPS.md` — it's generated by `scripts/regen-followups.py`. Edit the source (sidecar) and regen.
- Never write a MASTERPLAN row without a matching sidecar, or a sidecar without a MASTERPLAN row. Both or neither.
- Never edit historical BUILDLOG entries — BUILDLOG is append-only; `follow_ups[]` on the source sidecar is the disposition layer.
- `--all` is backfill only. After first run on adoption, use single-ID mode in the normal ship flow.
- Bullets already covered by the source sidecar's `follow_ups[]` are skipped silently — this is what makes the command idempotent.
