---
description: Fast-path for trivial changes on prefixes with `fast_path: true` — no worktree, no reviewer subagent. Usage — /patch <TASK-ID>
argument-hint: <TASK-ID>
---

You are running the fast-path for task **$ARGUMENTS**. This is the ceremony-reduced path for truly trivial changes on prefixes whose `fast_path: true` in `ritual.config.yaml` — no worktree, no `/check` / `/review` / `/walk` / `/ship` orchestration. The operator takes responsibility for the review that the subagent would have done; the revert trail in `BUILDLOG.md` is preserved.

`/patch` is **re-entrant**: the same invocation does setup (phase 1) or landing (phase 2), chosen by the sidecar state. Run it twice per task, with edits and a manual check in between.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Eligibility (both phases enforce)

- Prefix must have `fast_path: true` in `ritual.config.yaml`. Detect via:
  ```bash
  TASK_PREFIX="$(echo "$ARGUMENTS" | cut -d- -f1)"
  FAST_PATH="$(bash .claude/ritual/scripts/ritual-config.sh get prefixes.${TASK_PREFIX}.fast_path)"
  if [ "$FAST_PATH" != "true" ]; then
    echo "Prefix ${TASK_PREFIX} does not allow /patch — use /build + the full ritual."
    exit 1
  fi
  ```
- Diff heuristic (operator-attested, verified at phase 2): **<= ~20 lines changed across <= 2 files, no migration, no schema change, no new test file.** If the change outgrows this, abort phase 2 and start over via `/build <ID>` (standard ritual).
- Prefix-specific restrictions are project-defined in `ritual.config.yaml` under `prefixes.<P>.fast_path_forbidden_paths` (glob list). Common entries: novel access-control policies, schema/config files, lock-files. Any forbidden path in the diff → abort and route through full ritual.

## Phase detection

Read `.taskstate/<ID>.json`:

- `status: todo` → **Phase 1 (init)**.
- `status: in-progress` with `branch: task/<id-lowercase>-*` and `worktree: null` → **Phase 2 (land)**.
- Any other status → stop and report (already patched / shipped / in full ritual — do not cross streams).

---

## Phase 1 — init

Run from the main checkout at repo root.

1. Confirm eligibility (prefix, sidecar).
2. Read `MASTERPLAN.md`; confirm deps — each listed ID's sidecar must be `status: shipped`, `status: patched`, or `status: blitzed` (per [ADR 0032](../../decisions/0032-blitz-fast-path.md) — blitzed tasks satisfy deps identically).
3. Pick a slug (kebab-case, from the task subject).
4. `git fetch origin`.
5. Ensure current branch is `main` and working tree is clean. If not, stop: `"Commit or stash your current work before /patch. Patch flow runs in the main checkout."`
6. Create and check out a task branch from fresh `origin/main`:
   ```
   git checkout -b task/<id-lowercase>-<slug> origin/main
   ```
7. Flip `.taskstate/<ID>.json` → `status: in-progress`, `branch: task/<id-lowercase>-<slug>`, `worktree: null`, refresh `updated_at`.
8. Commit that single-file change as `chore: start <ID>` with the task trailer.
9. Read the PRD and brief the operator:

```
Patch branch: task/<id-lowercase>-<slug>   (main checkout, no worktree)
Sidecar: status → in-progress
PRD: <refs>

Acceptance criteria (from PRD):
  - <criterion 1>
  - <criterion 2>

Edit the files. Commit as you go (each commit with the trailer keys defined in
commit.trailer_keys).

Run the prefix-specific manual check (the same gate /check would run):

  $(bash .claude/ritual/scripts/ritual-config.sh prefix.task_specific "<PREFIX>")

When green, re-run  /patch <ID>  to land it.
```

Stop here. Phase 2 happens on the next invocation.

---

## Phase 2 — land

Re-entered with `status: in-progress` and the patch branch checked out.

1. Confirm `git branch --show-current` matches sidecar `branch`. Off → stop.
2. `git status` — must be clean (all edits committed with trailers).
3. **Heuristic gate.** Run `git diff --shortstat main...HEAD`. If lines changed > 40 or files touched > 3, stop: `"Patch outgrew the fast-path heuristic. Abort /patch and restart via /build <ID> for full ritual."` (The <=20/<=2 budget has ~2x tolerance; past that, trust is spent.)
4. **Forbidden-surface gate.** If the diff includes any path matching `prefixes.<P>.fast_path_forbidden_paths` from `ritual.config.yaml` (typically test-file additions, migrations, novel access-control policies), stop and redirect to `/build`.
5. Acquire the ship lock (same as `/ship`, path `<repo-root>/.ship.lock`, same stale-detection logic). Fast-path and full-path compete for the same lock — `main` stays linear.
6. Rebase on latest `main`:
   ```
   git fetch origin
   git rebase origin/main
   ```
   Conflict → stop, release lock, report. Operator resolves and re-runs `/patch <ID>`.
7. Push & merge:
   - If remote exists: `git push -u origin task/<id-lowercase>-<slug>` → `gh pr create` (minimal body: PRD refs, Revert) → `gh pr merge --auto --squash --delete-branch`. Poll with `gh pr view --json state,mergedAt`.
   - Local-only: `git checkout main && git merge --squash task/<id-lowercase>-<slug>`; commit with the full trailer; `git branch -D task/<id-lowercase>-<slug>`.
8. Capture the squash SHA: `git rev-parse HEAD`.
9. On `main`:
   - Flip `.taskstate/<ID>.json` → **`status: patched`** (terminal), `pr` (URL or `local`), `commit` (squash SHA), refresh `updated_at`.
   - Append a **minimal** BUILDLOG entry wrapped in the standard anchors (per [ADR 0021](../../decisions/0021-reduce-context-bloat-buildlog-followups.md)):

     ```markdown
     <!-- TASK:<ID>:START -->

     ## YYYY-MM-DD HH:MM — <ID> <subject> (patched)

     - Path: `/patch` fast-path
     - PR: <url or local>
     - Squash: `<sha>`
     - Files: `<path1>`, `<path2>`
     - Revert: `git revert <sha>` (+ config rollback if applicable)

     <!-- TASK:<ID>:END -->
     ```

   No `Walk notes` section — `/patch` has no walk. No `Follow-ups:` section — if follow-ups exist, the change was not actually trivial; abort and redo via full ritual.
10. Commit on `main` as `chore: ship <ID>` with the trailer (same as `/ship`). Staged files: `.taskstate/<ID>.json`, `BUILDLOG.md`.
11. `git push origin main` (if remote).
12. Release the lock (`rm -rf "$LOCK"`).

## Report

```
### Patched — <ID> — <subject>

- Squash: <sha>
- PR: <url or local>
- Files: <count> / Diff: <lines>
- Sidecar: status → patched
- BUILDLOG: minimal entry appended

Ready for /plan-next.
```

## Never

- Never run `/patch` on prefixes whose `fast_path: false` (or absent). They go through the full ritual.
- Never create a worktree. The whole point is that the change is small enough to edit in place on main checkout.
- Never skip the BUILDLOG append. The revert trail is non-negotiable, fast-path or not.
- Never promote follow-ups from a patch. If a follow-up exists, the change was misclassified — abort and rerun via `/build`.
- Never release the lock before `main` push completes.
- Never bypass the heuristic gate in phase 2 by adding `--force`. If you're reaching for a force flag, use `/build`.
