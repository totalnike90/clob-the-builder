---
description: Squash-merge the task branch under a ship lock, update BUILDLOG + sidecar, remove worktree. Usage — /ship <TASK-ID>
argument-hint: <TASK-ID>
---

You are shipping task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md)). Multiple tasks can be in flight in parallel worktrees, but `/ship` is the **serialization point**: it holds `.ship.lock` locally and relies on GitHub's merge queue (`gh pr merge --auto`) remotely so only one ship touches `main` at a time.

## Preflight — must run inside the task's worktree

1. Read `<repo-root>/.taskstate/$ARGUMENTS.json`. Confirm:
   - `status: reviewed` (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md), supersedes ADR 0007 + [ADR 0018](../../decisions/0018-collapse-walk-fastpath-into-review.md) which gated on `walked`). `walked` → run `/check <ID>` then `/review <ID>`. `built` → run `/walk <ID>` (UX iteration or non-UX auto-skip), then `/check`, then `/review`. `in-progress` → build not finished. No overrides without an ADR.
   - `pwd` matches sidecar `worktree`; `git branch --show-current` matches `branch`.
2. `git status` inside the worktree — must be clean.

## Pre-lock: staging-cloud parity gate (per [BP-31](../../BUILDLOG.md))

Before acquiring the ship lock, verify staging cloud is not behind `origin/main`. Run `bash scripts/check-staging-parity.sh --quiet`. The script fast-paths (exit 0) when the current branch adds no migrations. When it fails (exit 1 or 2), stop the ship and follow the operator workflow it prints — typically `git checkout main && bash scripts/catch-up-staging.sh`, commit the cursor advance, push, rebase, retry.

This closes the silently-broken MASTERPLAN line 109 rule ("From SC-3 onward, each task must `supabase db push` to the cloud staging project before /ship") that drifted unnoticed from approximately SC-5 (2026-04-20) until BP-29's /ship pre-flight surfaced the gap.

```bash
if ! bash scripts/check-staging-parity.sh --quiet; then
  echo "Staging parity check failed — see above. Cannot ship until staging is caught up."
  exit 1
fi
```

## Acquire the ship lock

Lock lives in the **main checkout** (repo root), not the worktree. Path: `<repo-root>/.ship.lock` (gitignored). Per [ADR 0008](../../decisions/0008-ritual-consistency-fixes.md), the lock carries owner PID + acquisition timestamp so a crashed session doesn't wedge future ships. TTL: 30 minutes. Stale (dead PID **or** age >30 min) → remove and retry once.

```bash
REPO_ROOT="$(git worktree list --porcelain | awk '/^worktree/ {print $2; exit}')"
LOCK="$REPO_ROOT/.ship.lock"

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK/owner"
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  read -r LOCK_PID LOCK_AT < "$LOCK/owner" 2>/dev/null || true
  STALE=0
  if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then STALE=1; fi
  if [ -n "$LOCK_AT" ]; then
    AGE=$(( $(date -u +%s) - $(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LOCK_AT" +%s 2>/dev/null || echo 0) ))
    [ "$AGE" -gt 1800 ] && STALE=1
  fi
  if [ "$STALE" = 1 ]; then
    echo "Stale .ship.lock (pid=$LOCK_PID age=${AGE:-?}s) — removing and retrying."
    rm -rf "$LOCK"
    acquire_lock || { echo "Still cannot acquire lock after stale cleanup."; exit 1; }
  else
    echo "Another /ship is in progress (pid=$LOCK_PID since $LOCK_AT). Try again when it finishes."
    exit 1
  fi
fi
```

Lock is a directory created atomically by `mkdir`; owner metadata in `$LOCK/owner`. Release is a single `rm -rf "$LOCK"` at the end — no fd bookkeeping. `mkdir` is POSIX-portable — no external binary.

## Rebase on the latest main

3. Snapshot `origin/main`, then fetch:

   ```bash
   MAIN_BEFORE=$(git rev-parse origin/main 2>/dev/null || echo "none")
   git fetch origin
   MAIN_AFTER=$(git rev-parse origin/main)
   ```

4. **Fast path** — if `MAIN_BEFORE = MAIN_AFTER`: `origin/main` hasn't advanced since `/check` ran; the worktree code is identical to what already passed quality gates. Skip the rebase and the quality-gate re-run entirely.

   **Slow path** — if `MAIN_BEFORE ≠ MAIN_AFTER`: a sibling shipped; rebase and re-verify:
   - `git rebase origin/main` — abort and report on conflict. Parallel-ship conflicts mostly hit `BUILDLOG.md` (sibling task shipped); keep both entries with yours (newer) on top.
   - Re-run quality gates **in parallel** (saves 5–15s over sequential `&&`):

     ```bash
     pnpm format:check & FPID=$!
     pnpm lint         & LPID=$!
     pnpm typecheck    & TPID=$!
     wait $FPID; FC=$?
     wait $LPID; LC=$?
     wait $TPID; TC=$?
     [ $FC -eq 0 ] && [ $LC -eq 0 ] && [ $TC -eq 0 ] || { echo "Quality gates failed post-rebase"; exit 1; }
     ```

## Gather ship metadata

- Task ID, subject, Slice (1 or 2), PRD refs
- Branch name (from sidecar)
- Files touched: `git diff --name-only main...HEAD`
- Migrations added: `git diff --name-only main...HEAD -- supabase/migrations/`
- Acceptance criteria (copy from PRD)
- Non-blocking follow-ups the reviewer flagged
- `walk_notes` from sidecar — copy verbatim into BUILDLOG under `Walk notes`, including `fail → later passed` attempts (durable human-judgment trail per ADR 0007)
- Revert command (see BUILDLOG rules)

## Step 7.5 — triage follow-ups, pre-merge (per [ADR 0026](../../decisions/0026-ship-speed-triage-before-merge.md), [ADR 0006](../../decisions/0006-followup-triage-register.md), [ADR 0020](../../decisions/0020-batch-dispositions-ship-step-7-5.md))

Triage now happens **before** `gh pr create` so it overlaps with GitHub CI rather than adding to the lock hold time. Follow-up bullets come from the reviewer notes already in the sidecar — the same bullets that will appear in BUILDLOG. Dispositions are collected here; they are written to the sidecar and regenerated into `FOLLOWUPS.md` after the merge completes (in Step 7).

If the `Follow-ups:` list is empty or says `none`, skip — no prompt.

**Auto-mode detection (per [ADR 0031](../../decisions/0031-automated-ritual-mode.md)):** if sidecar has `auto_mode: true`, inspect `follow_ups[]` for entries with `disposition: "resolved"` whose `target` equals the current task ID — these were auto-applied as `chore: polish <ID>` commits by `/auto` after `/review` Pass and are already dispositioned. Exclude them from the prompt list. If the remaining bullets are zero, skip Step 7.5 entirely. Clear the transient `auto_mode: true` flag during the sidecar write in Step 7. Manual `/ship` invocations are unaffected — sidecars without the flag follow the existing flow verbatim.

Otherwise, list all bullets and offer a batch option first (per [ADR 0020](../../decisions/0020-batch-dispositions-ship-step-7-5.md)):

```
Follow-ups for <ID>: <N> bullets.

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

**A. Drop all.** Prompt once for a reason string (required, non-empty). Collect N objects, all `disposition: "dropped"`, same `note: <reason>`.

**B. Promote all — bundle.** Prompt once: phase / new ID / subject / deps / PRD refs (same ID-collision check). Collect N objects, all `disposition: "promoted"`, same `target: <NEW-ID>`. Stage one MASTERPLAN row + one sidecar to write after merge.

**C. Fold all.** Prompt once for target task ID (must exist in MASTERPLAN). Collect N objects, all `disposition: "folded"`, same `target: <TARGET-ID>`.

**D. Resolved all.** Prompt once for resolver task ID (must appear as `^<!-- TASK:<ID>:START -->` in BUILDLOG). Collect N objects, all `disposition: "resolved"`, same `target: <RESOLVER-ID>`.

**Enter / `n`.** Per-bullet loop — same questions as before (Promote / Fold / Drop / Resolved). Collect one object per bullet.

Hold all collected dispositions in memory. They are written to disk in Step 7 after the merge, in the same `chore:ship <ID>` commit.

## Merge

### Path A — GitHub remote (primary once CI is wired)

1. `git push -u origin $(git branch --show-current)`
2. `gh pr create` — Title: `<ID>: <subject>`. Body HEREDOC with Summary / PRD refs / Acceptance criteria / Test plan / Revert sections.
3. `gh pr merge --auto --squash --delete-branch` — `--auto` queues behind running checks and serializes against concurrent ships server-side. Do not wait at the terminal; poll with `gh pr view --json state,mergedAt`.
4. Once merged: `git checkout main && git pull --ff-only`.
5. Capture the squash SHA: `git rev-parse HEAD`.

### Path B — No remote (local-only, early days)

1. `cd` to the main checkout (`git worktree list --porcelain | awk '/^worktree/ {print $2; exit}'`).
2. `git pull --ff-only` (no-op if local).
3. `git merge --squash task/<ID_LC>-<SLUG>`
4. Build the squash commit message (subject `<ID>: <subject>` + bullet body + trailer block) via HEREDOC.
5. `git commit` → capture SHA with `git rev-parse HEAD`.
6. `git branch -D task/<ID_LC>-<SLUG>`.

## Update shared files on main

7. On `main` (main checkout):
   - Flip `.taskstate/<ID>.json` → `status: shipped`; set `pr` (URL or `local`), `commit` (squash SHA); refresh `updated_at`. Apply the `follow_ups[]` dispositions collected in the pre-merge Step 7.5 (above). For any `promoted` dispositions, also write the new `.taskstate/<NEW-ID>.json` sidecars and append MASTERPLAN rows now.
   - Append a new block to `BUILDLOG.md` using the template (newest on top). Include date, Task ID + subject, Slice, Branch (now deleted), PR URL or `local`, squash SHA, full file list, migrations added, acceptance criteria with ✓, revert command, follow-ups. **Wrap in stable anchors** (per [ADR 0021](../../decisions/0021-reduce-context-bloat-buildlog-followups.md)):

     ```markdown
     <!-- TASK:<ID>:START -->

     ## YYYY-MM-DD HH:MM SGT — <ID> <subject>

     ...entry body...

     <!-- TASK:<ID>:END -->
     ```

     Anchors enable O(1) per-task slicing via `scripts/slice-buildlog.py <ID>` instead of awk-scanning the whole file.

   - Run `python3 scripts/regen-followups.py` once — rewrites `FOLLOWUPS.md` from all sidecars + `.taskstate/_notes.json`.

8. Commit all changes on `main` as `chore: ship <ID>` with the trailer. Staged files:
   - `.taskstate/<ID>.json` (flipped to shipped; `follow_ups[]` populated if bullets existed)
   - `BUILDLOG.md` (new entry wrapped in TASK anchors)
   - `FOLLOWUPS.md` (regenerated — if any follow-ups existed)
   - `MASTERPLAN.md` (appended rows — only if any promotion happened)
   - `.taskstate/<NEW-ID>.json` for each promoted follow-up

## Push (if remote exists)

9. `git push origin main`.

## Cleanup the worktree

10. `git worktree remove .worktrees/<ID_LC>` — from the main checkout.
11. If Path A was used, `git branch -D task/<ID_LC>-<SLUG>` locally (remote already deleted by `--delete-branch`).

## Release the lock

12. `rm -rf "$LOCK"` — removes the directory and its owner file together.

## Report to the user

```
### Shipped — <ID> — <subject>

- Squash commit: <sha>
- PR: <url or local>
- Files touched: <count>
- Migrations: <count>
- Sidecar: .taskstate/<ID>.json → shipped ✓
- BUILDLOG: appended
- Worktree .worktrees/<ID_LC>: removed
- Ship lock: released

Ready for `/plan-next`.
```

## Never

- Never force-push to `main`.
- Never `--amend` the squash commit — fix a wrong BUILDLOG entry in a follow-up `chore: buildlog fix <ID>` commit.
- Never skip the BUILDLOG update. The revert index is useless with gaps.
- Never skip Step 7.5 triage when follow-ups exist — unregistered bullets break the `/plan-next` drift gate and let real work rot.
- Never ship a task whose `Deps` are not all in sidecar `status: shipped`. Mid-ship discovery → stop and file an ADR.
- Never release the lock before the `main` push completes — losing the lock mid-flight lets a sibling ship race.
- If a migration shipped, the revert command in BUILDLOG must include the specific down-migration or `supabase db reset` step.
- If this is a phase-closing task (no sibling sidecar `todo` or `in-progress`), note that in the BUILDLOG entry — next `/plan-next` picks up the next phase.
