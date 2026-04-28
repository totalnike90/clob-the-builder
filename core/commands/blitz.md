---
description: Session-level ritual bypass — iterate live, land one squash commit per task. Usage — /blitz [--i-know]
argument-hint: [--i-know]
---

You are driving a **session-level ritual bypass** per [ADR 0032](../../decisions/0032-blitz-fast-path.md), extended by [ADR 0034](../../decisions/0034-blitz-adhoc-and-scope-brief.md) (ad-hoc trailers + init scope brief). `/blitz` covers one task or many in a single live-iteration session against the dev server. `/review` + `/walk` are skipped; cheap gates (`format` + `lint` + `typecheck`) still run at land. Every granular commit must carry exactly one `Task: <ID>` trailer — task discovery happens at land-time by scanning trailers. Ad-hoc work uses `Task: NEW-<slug>` placeholders that resolve at land into a real MASTERPLAN ID (promote a new row, or fold into an existing row). `main` linearity is preserved via the shared `.ship.lock`. The 1:1 task/revert invariant is preserved — `/blitz` creates one squash commit per resolved task ID.

Parse `$ARGUMENTS`:
- `--i-know` — if present, records operator override for risky-surface touches (project-defined in `ritual.config.yaml` — typically migrations, schema/config files, RLS policies, rollback files). Persisted in `.taskstate/_blitz.json` so both phases honour it.

## Phase detection

Read the current git branch:

- `main` (clean tree) → **Phase 1 (init)**.
- `blitz/<slug>` (matches `.taskstate/_blitz.json.branch`) → **Phase 2 (land)**.
- Anything else → stop: `"/blitz runs on main (init) or on a blitz/<slug> branch (land). You are on <branch>."`

If `.taskstate/_blitz.json` exists on `main` with no matching branch on disk, offer cleanup: `"Stale blitz marker found (slug=<slug>, started <ISO>). Remove it to start fresh?"` — operator confirms before deletion.

---

## Phase 1 — init

Run from repo root on `main`.

1. `git fetch origin`.
2. Require current branch = `main` and working tree clean. Else stop: `"Commit or stash current work before /blitz. Blitz runs from a clean main."`
3. Ask operator for a session slug: short kebab-case descriptor of the session's intent (e.g. `polish-pass`, `onboarding-fixes`).
4. **Optional intent + scope brief** ([ADR 0034](../../decisions/0034-blitz-adhoc-and-scope-brief.md)):
   ```
   Describe what you intend to build this session (blank to skip):
   ```
   - Blank → skip the brief; record `intent: null`, `scope_brief: null` in the marker.
   - Non-blank → run the deconfliction brief:
     1. Tokenize intent: lowercase, drop common stopwords (`a, an, the, and, or, to, of, for, in, on, with, that, this`), keep tokens with length >= 3.
     2. Grep `MASTERPLAN.md` rows whose subject column matches any keyword (case-insensitive). Cap at top 5 by token-hit count, ordered by phase+ID. For each match, capture `<ID>`, `<subject>`, sidecar status from `.taskstate/<ID>.json`.
     3. Grep the PRD (`{{paths.prd}}`) for headers (`^#{1,4} `) matching any keyword (case-insensitive). Cap at top 5. For each match, capture `<ref>`, header text, and a stub heuristic — section is "stub" if its body until the next header is fewer than 5 non-blank lines.
     4. Print:
        ```
        Scope brief: "<intent>"

        Existing MP rows that may overlap:
          - <ID> — <subject> (<status>)
          ...
          (or "none — keyword grep found no overlap" if zero hits)

        PRD sections referenced:
          - <ref> <header> — <stub | non-stub>
          ...
          (or "none" if zero hits)

        Suggested paths:
          - Extend an overlapping MP row if scope is purely additive
          - Fold into one if related UX
          - Or: proceed as Task: NEW-<your-slug> for genuinely new scope
        ```
     5. Persist `intent` (string) and `scope_brief` (the printed text) in `_blitz.json`. They land in the bundled BUILDLOG preamble at Phase 2 Step 10.

   The brief is informational. No edits are made, no gates run, no sidecar mutations. Operator reads it, decides, proceeds.

5. Create the session branch:
   ```
   git checkout -b blitz/<slug> origin/main
   ```
6. Write `.taskstate/_blitz.json`:
   ```json
   {
     "slug": "<slug>",
     "branch": "blitz/<slug>",
     "i_know": <bool>,
     "intent": "<string or null>",
     "scope_brief": "<full brief text or null>",
     "started_at": "<ISO-8601 UTC>",
     "staged_edits": []
   }
   ```
7. Commit that single file as `chore: start blitz <slug>` with the trailer `Task: BLITZ` (any other trailer keys per `commit.trailer_keys` are project-defined). The synthetic `BLITZ` trailer is never surfaced in BUILDLOG — Phase 2's trailer scan skips it.
8. Brief the operator:

```
Blitz session: blitz/<slug>
Marker: .taskstate/_blitz.json
Override: <--i-know enabled | none>
Intent: <intent or "skipped">

Iterate freely:
  - Edit any files you need across any tasks (existing MP rows or new scope).
  - Run the project's dev server and verify in-browser as you go.
  - Every commit MUST carry exactly one  Task: <ID>  trailer.
    Commits spanning two tasks → split into two commits (use git rebase -i if needed).

  Trailer ID forms accepted:
    - <existing MP ID>     — must have non-terminal sidecar:
        todo                 — for prefixes whose pre_build_plan_gate is false
        planned              — for prefixes whose pre_build_plan_gate is true
                              (run /plan-build first)
    - NEW-<your-slug>      — placeholder for ad-hoc work without a MP row.
                             Resolved at land into a real ID via:
                               (a) Promote — create a new MP row + sidecar
                               (b) Fold    — bucket into an existing MP ID
                               (c) Abort   — halt the session, no partial ship

  Deps per task are re-checked at land (shipped / patched / blitzed all accepted).
  PRD edits are first-class: edit the PRD inside any task's commits.
  Reconciliation will surface the changes at land.

When done, run  /blitz  again on this branch to land.

At land, /blitz will:
  1. Scan commit trailers; list every task ID covered (real + NEW-*).
  2. Per task: verify MASTERPLAN row + sidecar + deps + risky-surface gate
     (NEW-* IDs skip the MP-row/sidecar/deps checks; resolved in step 3).
  3. Scope reconciliation (per task) — for real IDs: show diff vs MASTERPLAN
     row PRD refs and prompt for MASTERPLAN/PRD edits if drift. For NEW-*:
     forced resolution prompt (Promote / Fold / Abort).
  4. Run format + lint + typecheck in parallel.
  5. Create one squash commit per resolved task ID on main (trailer-first-seen order).
  6. Append ONE bundled BUILDLOG session entry with per-task anchors.
  7. Flip every covered sidecar to status: blitzed.
```

Stop. Operator iterates.

---

## Phase 2 — land

Re-entered on `blitz/<slug>` branch.

1. Confirm current branch matches `.taskstate/_blitz.json.branch`. Off → stop.
2. `git status` clean. All edits committed with trailers.

### Step 1 — Trailer scan

```bash
git log origin/main..HEAD \
  --pretty=format:'%H%x09%s%x09%(trailers:key=Task,valueonly,separator=|)' \
  > /tmp/blitz-commits.tsv
```

For each line, extract SHA, subject, Task trailer:
- Empty Task → stop: `"Commit <sha> (\"<subject>\") has no Task: trailer. Add one via git rebase -i (no --amend) and re-run /blitz."`
- Multiple Task values (separator=`|`) → stop: `"Commit <sha> has multiple Task trailers. Each commit = exactly one task. Split via git rebase -i and re-run /blitz."`
- `Task: BLITZ` (Phase 1 marker) → skip.
- `Task: NEW-<slug>` ([ADR 0034](../../decisions/0034-blitz-adhoc-and-scope-brief.md)) — accepted as a placeholder ID. Validate slug matches `^NEW-[a-z][a-z0-9-]*$`; otherwise stop and report the bad slug. Multiple distinct `NEW-*` slugs in one session are fine; they roll up by slug into separate resolution prompts in Step 4.

Build `TASK_COMMITS`: ordered map `ID → [sha1, sha2, ...]` (preserves trailer-first-seen order across both real and `NEW-*` IDs).

### Step 2 — Per-task preflight

For each unique task ID in `TASK_COMMITS`:

- **`NEW-<slug>` IDs** — skip all three checks below. They have no MASTERPLAN row by definition; resolution happens in Step 4. Risky-surface gate (Step 3) and cheap gates (Step 5) still apply unchanged to their commits.
- **Real IDs** — run all three checks:

  1. MASTERPLAN row exists. Missing → stop naming the ID.
  2. Read `.taskstate/<ID>.json`. Status must be:
     - `todo` for prefixes whose `pre_build_plan_gate: false` (or absent).
     - `planned` for prefixes whose `pre_build_plan_gate: true`. `todo` → stop: `"/plan-build <ID> first — this prefix requires a plan gate."`
     - Anything else → stop: `"<ID> is <status> — remove its commits from this session or drop the session."`
  3. Each `Deps` ID's sidecar must be `shipped` / `patched` / `blitzed`. Missing → stop naming the blocking dep.

### Step 3 — Risky-surface gate

Compute `git diff --name-only origin/main...HEAD`. Risky surfaces are project-defined in `ritual.config.yaml` under a `blitz.risky_surfaces` array (glob patterns or path prefixes). Typical entries:

- migration files / database-versioning paths
- non-application config that affects all developers (lock-files, docker-compose, env templates)
- access-control / RLS policy files
- rollback or down-migration paths

If any matched path is in the diff and `_blitz.json.i_know !== true` → stop:

```
/blitz refuses to touch <matched surfaces> without --i-know.

These surfaces have complex revert semantics — see ritual.config.yaml
`blitz.risky_surfaces` for the project-defined list.

If you're sure, re-run:  /blitz --i-know
Otherwise, squash the offending commits out via  git rebase -i  and re-run.
```

With `--i-know`: proceed. BUILDLOG will record the matched paths + override flag.

### Step 4 — Scope reconciliation (per task)

For each task ID in `TASK_COMMITS`:

0. **Resolve `NEW-<slug>` placeholders** ([ADR 0034](../../decisions/0034-blitz-adhoc-and-scope-brief.md)).

   Skip this sub-step for real IDs. For `NEW-*` IDs:

   First, check `_blitz.json.staged_edits` for an entry of type `adhoc_resolution` keyed by this `NEW-<slug>`. If present, the resolved ID is recorded there — skip to "apply resolution" below (prevents re-asking after Phase 2 retry).

   Otherwise, prompt:

   ```
   === Ad-hoc trailer resolution: NEW-<slug> ===

   Files touched (N) : <file list>
   Granular subjects:
     - <subject1>
     - <subject2>

   How should this work be resolved?
     P  — Promote to a new MASTERPLAN row
     F  — Fold into an existing MASTERPLAN row
     A  — Abort the entire blitz session (no partial ship)
   ```

   - **P (Promote).** Sequential prompts (same field set as Step 7.iii):
     - Phase prefix (any prefix listed in `prefixes:` in `ritual.config.yaml`).
     - New MASTERPLAN ID — must not collide with any existing MASTERPLAN row or `.taskstate/<ID>.json` file. Reject and re-prompt on collision.
     - Subject (one line).
     - Deps (comma-separated MASTERPLAN IDs, or blank). Each declared dep's sidecar must be `shipped` / `patched` / `blitzed`; reject and re-prompt on a missing or non-terminal dep.
     - PRD refs.
     - Any additional trailer keys defined in `commit.trailer_keys`.
     Stage `{ "type": "adhoc_resolution", "placeholder": "NEW-<slug>", "mode": "promote", "new_id": "<NEW-ID>", ... }`.
   - **F (Fold).** Prompt for an existing MASTERPLAN ID. Validate: row exists; sidecar status is non-terminal (`todo`/`planned`/`in-progress`/`built`/`walked`/`reviewed` — lattice per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)). Status `shipped`/`patched`/`blitzed`/`reverted`/`blocked` → reject and re-prompt. Stage `{ "type": "adhoc_resolution", "placeholder": "NEW-<slug>", "mode": "fold", "target_id": "<EXISTING-ID>" }`.
   - **A (Abort).** Persist current `_blitz.json.staged_edits`, release any acquired lock, exit:
     ```
     Blitz session aborted at NEW-<slug> resolution. No commits landed.
     Either drop the NEW-<slug> commits via  git rebase -i  and re-run /blitz,
     or accept that the session won't ship as-is.
     ```

   **Apply resolution to in-memory state** (so the rest of Step 4 + Step 9 see the real ID):
   - Promote: rename the `TASK_COMMITS` key from `NEW-<slug>` → `<NEW-ID>`. Treat as a synthetic real ID for the remaining sub-steps; its MASTERPLAN row + sidecar don't exist yet (created at Step 10), so:
     - Step 4.3–4.7 run normally using the operator-supplied subject / Deps / PRD refs as the "MASTERPLAN row" surrogate (no row update prompt — this is a *new* row, so 4.7.i is auto-skipped).
     - Treat its sidecar status as if it were already eligible for blitzing (no preflight re-run).
   - Fold: rename the `TASK_COMMITS` key from `NEW-<slug>` → `<EXISTING-ID>`. If `<EXISTING-ID>` already had its own commits in `TASK_COMMITS` (operator was extending an existing task *and* doing ad-hoc work that should fold into it), merge the SHA lists in trailer-first-seen order; deduplicate. The combined entry then runs Step 4.1–4.7 once for the union.
   - Persist updated `_blitz.json.staged_edits` to disk before continuing (retry safety).

1. **Skip if already reconciled this session.** Check `_blitz.json.staged_edits` for an entry keyed by this `<ID>`. If present, skip to next task (prevents re-asking after Phase 2 retry).

2. Derive the task's file list:
   ```bash
   TASK_FILES=$(for sha in "${TASK_COMMITS[<ID>]}"; do git show --name-only --format= "$sha"; done | sort -u)
   ```

3. Read the MASTERPLAN row; extract subject, `Deps`, `PRD` column.

4. Read the PRD sections from `{{paths.prd}}`. Extract lightweight surface hints per section — filename tokens, `/path` endpoints, PascalCase component names, cross-refs. Best-effort parser; a reading aid, not a gate.

5. Display the three-column summary:

   ```
   === Scope reconciliation: <ID> — <subject> ===

   MASTERPLAN row PRD refs : <refs>
   Files touched (N)       : <file1>
                             <file2>
   PRD surface hints       : <hints>

   Anything drift from what the row expects?
     N — proceed, no updates needed
     Y — reconcile MASTERPLAN row and/or PRD before landing
   ```

6. **On N:** record `{ "task": "<ID>", "actions": [] }` in `staged_edits`. Proceed.

7. **On Y — reconcile loop.** Three sub-prompts, each Y/N:

   **i. MASTERPLAN row update?**
   ```
   Current PRD column: <current>
   Type replacement (or Enter to keep):
   ```
   If operator types a new value: stage `{ "type": "masterplan_row_update", "id": "<ID>", "field": "PRD", "new": "<value>" }`. Offer sequential prompts for subject / Deps if operator asks (`"also update subject? also update Deps?"`).

   **ii. PRD section update?**
   ```
   Implementation may have drifted from <ref-list>. Update any?
     (open <ref> / N)
   ```
   On `open <ref>`: record PRD file mtime, then:
   ```bash
   "${EDITOR:-${VISUAL:-nvim}}" "{{paths.prd}}"
   ```
   Fall back to `vi` if `nvim` missing. Operator edits, saves, exits. Re-check mtime:
   - Changed → stage `{ "type": "prd_edit", "ref": "<ref>", "file": "{{paths.prd}}" }` and snapshot the file into `.taskstate/_blitz.staged.<slug>/prd.md` (so Phase 2 retries see the operator's edit even if they revert the PRD file externally).
   - Unchanged → no stage.

   **iii. New MASTERPLAN row needed?**
   ```
   Did this blitz surface work that belongs to a new MASTERPLAN row?
     N — no new row
     Y — prompt for phase / new ID / subject / deps / PRD refs
   ```
   On Y: same fields as `/ship` Step 7.5 "promote". ID collision check (new ID must not exist in MASTERPLAN or `.taskstate/`). Stage `{ "type": "masterplan_new_row", "new_id": "<NEW-ID>", ... }`.

8. After each task's reconcile loop, persist `_blitz.json.staged_edits` to disk so a later Phase 2 failure doesn't lose the work.

9. Reconciliation summary per task goes into BUILDLOG sub-block (Step 10) as `Reconciliation: <short list>` or `Reconciliation: none`.

### Step 5 — Cheap safety gates (parallel)

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd format) & FPID=$!
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd lint)   & LPID=$!
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd typecheck) & TPID=$!
wait $FPID; FC=$?
wait $LPID; LC=$?
wait $TPID; TC=$?
[ $FC -eq 0 ] && [ $LC -eq 0 ] && [ $TC -eq 0 ] \
  || { echo "Cheap gates failed — fix and re-run /blitz."; exit 1; }
```

Any non-zero → stop. No lock acquired. Operator fixes with a new trailered commit; re-runs `/blitz`. Staged reconciliation edits persist in `_blitz.json.staged_edits` across retries.

### Step 6 — Acquire .ship.lock

Copy the exact `mkdir`-based lock block from [`ship.md`](ship.md) — same `.ship.lock` directory in main checkout, same owner-PID + acquisition-timestamp, same 30-minute TTL, same stale detection. `/blitz`, `/ship`, `/patch` all serialize through this lock; `main` stays linear.

### Step 7 — Rebase on latest main

```bash
MAIN_BEFORE=$(git rev-parse origin/main 2>/dev/null || echo "none")
git fetch origin
MAIN_AFTER=$(git rev-parse origin/main)
```

- `MAIN_BEFORE == MAIN_AFTER` → skip rebase + skip re-run of gates.
- Else:
  - `git rebase origin/main` — conflict → stop, release lock, report.
  - Re-run format + lint + typecheck in parallel (Step 5 block).

### Step 8 — Follow-up triage (per task)

For each task ID in `TASK_COMMITS`, prompt:

```
Any follow-ups to register for <ID>? (blank = none; else paste bulleted list)
```

Standard triage loop per-bullet (promote / fold / drop / resolved), batch option first. Hold dispositions in memory keyed by task ID.

### Step 9 — Multi-task squash sequence

For each unique task ID in `TASK_COMMITS` (trailer-first-seen order):

1. `git checkout main` (local main checkout; after step 7's rebase, your branch HEAD may differ from `main`).
2. For each SHA in `TASK_COMMITS[<ID>]`:
   ```bash
   git cherry-pick --no-commit <sha>
   ```
   - Clean apply → continue.
   - Conflict → abort the whole session:
     ```bash
     git cherry-pick --abort 2>/dev/null || true
     git reset --hard origin/main
     ```
     Release lock, report: `"Commits for <ID> conflict with a prior squash in this session. Tasks in a single blitz must touch disjoint files. Abort and restart as separate blitz sessions per task."`
3. Collect granular subjects:
   ```bash
   GRANULAR=$(for sha in "${TASK_COMMITS[<ID>]}"; do git log -1 --format='- %s' "$sha"; done)
   ```
4. Build squash commit message via HEREDOC. Trailer keys per `commit.trailer_keys`:
   ```
   <ID>: <subject-from-MASTERPLAN>

   ## Journey
   <GRANULAR>

   ## Blitzed in session
   blitz/<slug> (bundled with: <other task IDs or "none">)

   Task: <ID>
   ```
5. `git commit -F <heredoc>`; capture `SQUASH_<ID>=$(git rev-parse HEAD)`.

### Step 10 — Push + BUILDLOG + staged edits (atomic)

1. If `origin/main` exists:
   ```bash
   git push --atomic origin main
   ```
   Rejection (origin advanced between step 7 and step 9) → release lock, report, operator retries.

2. On `main`:

   **a. Apply ad-hoc resolutions first** (so sidecar flips below see the resolved IDs and any newly-created sidecars). For each `adhoc_resolution` in `_blitz.json.staged_edits`:
   - `mode: promote` → append new MASTERPLAN row using the staged fields. Write a fresh `.taskstate/<NEW-ID>.json` sidecar. The synthetic ID is now treated as a "covered" ID for sidecar flips below.
   - `mode: fold` → no MASTERPLAN/sidecar mutation here; the placeholder's commits already merged into `target_id`'s `TASK_COMMITS` entry in Step 4.0, and `target_id`'s existing sidecar gets flipped below.

   **b. Sidecar flips.** For each covered `<ID>` (post-resolution):
   - `.taskstate/<ID>.json` → `status: blitzed`, `pr: "main (blitz session blitz/<slug>)"`, `commit: "<SQUASH_<ID>>"`.
   - Append `follow_ups[]` from Step 8.
   - Append `reconciliation_notes` from Step 4's staged edits (including any `adhoc_resolution` entry that resolved to this ID — so the audit trail shows "originally NEW-<slug>").
   - Refresh `updated_at`.

   **c. Apply remaining staged reconciliation edits** from `_blitz.json.staged_edits`:
   - `masterplan_row_update` → regex-replace the row's field.
   - `prd_edit` → copy the snapshot `.taskstate/_blitz.staged.<slug>/prd.md` → `{{paths.prd}}`.
   - `masterplan_new_row` (Step 4.7.iii promotions, separate from `adhoc_resolution`) → append MASTERPLAN row + write new `.taskstate/<NEW-ID>.json` sidecar.

   **d. Promoted dispositions from Step 8** → write new `.taskstate/<NEW-ID>.json` sidecars and append MASTERPLAN rows.

   **e. Append one bundled BUILDLOG entry** (newest on top) wrapped in `<!-- TASK:BLITZ-<slug>:START -->` / `<!-- TASK:BLITZ-<slug>:END -->` anchors, with per-task sub-blocks wrapped in `<!-- TASK:<ID>:START -->` / `<!-- TASK:<ID>:END -->`:

     ```markdown
     <!-- TASK:BLITZ-<slug>:START -->

     ## YYYY-MM-DD HH:MM — Blitz session: <slug>

     - Path: `/blitz` session fast-path ([ADR 0032](decisions/0032-blitz-fast-path.md), extended by [ADR 0034](decisions/0034-blitz-adhoc-and-scope-brief.md))
     - Intent: <intent or "skipped">
     - Tasks covered: <ID1>, <ID2>, ...
     - Gates run: format · lint · typecheck (passed) · tests — skipped · build — skipped · task-specific — skipped
     - Bypass: `/review` + `/walk` skipped for all tasks in this session
     - Risky surfaces touched: <list or "none">  (Override: <--i-know or "n/a">)
     - Reconciliation summary: <aggregate or "none">
     - Ad-hoc resolutions: <count + summary or "none">

     <!-- TASK:<ID1>:START -->
     ### <ID1> — <subject>
     - Squash: `<SQUASH_ID1>`
     - Resolved from: NEW-<slug>  (omit line if not ad-hoc)
     - Files: <file list>
     - Journey:
       <granular bullets>
     - Reconciliation: <short list or "none">
     - Follow-ups: <list or "none">
     - Revert: `git revert <SQUASH_ID1>`
     <!-- TASK:<ID1>:END -->

     <!-- TASK:<ID2>:START -->
     ...
     <!-- TASK:<ID2>:END -->

     ### Session revert
     Undoes the whole session:  `git revert <SQUASH_ID1> <SQUASH_ID2> ...`

     <!-- TASK:BLITZ-<slug>:END -->
     ```

     Per-task anchors nested inside the session wrapper keep `scripts/slice-buildlog.py <ID>` working unchanged.

   **f. Regen FOLLOWUPS** — if any follow-ups were dispositioned: `python3 scripts/regen-followups.py`.

3. Commit everything on `main` as `chore: ship blitz <slug>` with trailer listing all covered task IDs:
   ```
   Task: <ID1>
   Task: <ID2>
   ...
   ```
   Staged files:
   - every flipped `.taskstate/<ID>.json`
   - `BUILDLOG.md`
   - `FOLLOWUPS.md` (if regenerated)
   - `MASTERPLAN.md` (if any row-update or new-row edits)
   - `{{paths.prd}}` (if any PRD edit)
   - `.taskstate/<NEW-ID>.json` per promoted/new row
   - removal of `.taskstate/_blitz.json` and `.taskstate/_blitz.staged.<slug>/` (session cleanup)

4. `git push origin main` (if remote exists).
5. `git branch -D blitz/<slug>` locally. If branch was pushed: `git push origin :blitz/<slug>`.
6. Release lock: `rm -rf "$LOCK"`.

### Report

```
### Blitzed — session <slug>

Tasks shipped: <N>
  - <ID1> — <subject>  (squash <SHA1>)
  - <ID2> — <subject>  (squash <SHA2>)
  ...

Cheap gates: format / lint / typecheck (passed)
All sidecars: status → blitzed
Reconciliation: <aggregate or "none staged">
BUILDLOG: bundled session entry appended with per-task anchors
Ship lock: released

Bypass summary: /review + /walk skipped for all <N> tasks. You owned verification.
<if --i-know: Risky surfaces touched: <list>. Individual reverts may require down-migration steps — see BUILDLOG.>

Ready for /plan-next.
```

---

## Never

- Never run `/blitz` without an in-browser dev-server check per task. That's the verification contract replacing `/review` + `/walk`.
- Never accept a commit without a `Task:` trailer at land. No exceptions — even a one-line typo fix needs its ID.
- Never accept commits with multi-value `Task:` trailers. Each commit belongs to exactly one task; split via `git rebase -i`.
- Never let `/blitz` proceed on cherry-pick conflicts between tasks — abort the whole session and restart as separate blitzes per task.
- Never `--amend` on a blitz branch — the granular trailers are the source of truth for the squash journey.
- Never squash-sequence without `.ship.lock`. `/blitz`, `/ship`, `/patch` all serialize through it.
- Never skip the BUILDLOG session entry. The bypass must be recoverable from `BUILDLOG.md` alone.
- Never let `/blitz` bypass the plan gate for prefixes whose `pre_build_plan_gate: true`. `status: planned` required; `todo` → redirect to `/plan-build`.
- Never auto-apply MASTERPLAN edits during Step 4 reconciliation. Every row change is operator-typed into the prompt; `/blitz` only stages it.
- Never auto-generate PRD prose. Open `$EDITOR`; operator writes the change. `/blitz` only stages based on mtime drift.
- Never skip Step 4 reconciliation. Blank answers (all N) are fine; silent skips are not. The prompt runs per task.
- Never bypass the `--i-know` gate by editing `_blitz.json` directly. If you need the override, re-run `/blitz --i-know`.
- Never let a `NEW-<slug>` placeholder reach `main`. Step 4.0 forces resolution (Promote / Fold / Abort); the squash trailer always carries a real MASTERPLAN ID.
- Never auto-pick the resolution mode for `NEW-*`. Operator types P / F / A explicitly.
- Never accept a Fold target with terminal sidecar status (`shipped` / `patched` / `blitzed` / `reverted` / `blocked`). Re-prompt until the operator picks an in-flight row.
- Never auto-generate scope-brief output. The brief is keyword grep over MASTERPLAN + PRD; if grep finds nothing, the brief says "none — keyword grep found no overlap" and the operator decides without LLM-paraphrased "suggestions" beyond the boilerplate three options (Extend / Fold / NEW).
