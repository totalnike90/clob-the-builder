---
description: Audit ritual state for drift across MASTERPLAN, sidecars, worktrees, branches, and main. Read-only by default. Usage — /doctor [--fix]
argument-hint: [--fix]
---

You are running a state-drift audit. The ritual splits canonical state across `MASTERPLAN.md`, `.taskstate/<ID>.json` sidecars (in main checkout AND each active worktree), `.worktrees/<id>/`, `task/*` branches, and `main`. These can drift silently — `/doctor` reads them all, cross-checks the invariants, and prints findings with recovery hints.

**Read-only by default.** `--fix` runs the same audit and then prompts the operator to apply each finding's recovery action interactively. No automatic destructive operations.

This command does **not** modify MASTERPLAN row status symbols on its own — that remains a manual operation via `scripts/sync-masterplan-status.py`. `/doctor --fix` will offer to invoke that script when symbol drift is detected, but only after the operator confirms.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Modes

- `/doctor` — audit only. Prints findings grouped by severity (BLOCK / WARN / INFO). Exits 0 if clean.
- `/doctor --fix` — audit, then for each finding ask the operator how to proceed.
- `/doctor --json` — machine-readable output for piping to scripts/CI.

## Preflight

Run from the repo root or any worktree — the script resolves the repo via `git`. No state preconditions; `/doctor` is intended to run on dirty trees.

## Invariants checked

For every task ID surfaced from MASTERPLAN, `.taskstate/`, `.worktrees/`, or `task/*` branches:

1. **MASTERPLAN row symbol matches sidecar status** — the trailing `Status` cell in MASTERPLAN, last refreshed by `scripts/sync-masterplan-status.py`, must agree with `.taskstate/<ID>.json` (worktree sidecar wins when a worktree is active).
2. **Sidecar is tracked in git** — untracked `.taskstate/<ID>.json` means `/plan-next` and the ritual see it but `git status` does not.
3. **In-flight tasks have a worktree + branch** — if sidecar is `in-progress | built | walked | reviewed` (lattice per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)), both must exist.
4. **Terminal sidecar implies a real ship commit on main** — `shipped | patched | blitzed` must trace to a commit subject `<ID>: <subject>` or `chore: ship <ID>` or a body trailer `Task: <ID>` on a non-intermediate commit.
5. **Stranded in-flight tasks** — worktree at `walked`/`reviewed` while main sidecar still `todo` and no ship on main → operator forgot `/check`/`/review`/`/ship`.
6. **Orphaned worktrees** — worktree exists but sidecar terminal: cleanup missed at `/ship`.

Plus global checks (only when invoked from `main`):

7. **Untracked sidecars** — `.taskstate/*.json` not in `git ls-files`.
8. **Untracked decision drafts** — `decisions/*.md` not in `git ls-files`.
9. **Dirty product code on main** — modifications under project source paths (configurable in `ritual.config.yaml` if needed) without a Task: trailer route.

## Steps

### 1. Run the audit

```bash
python3 scripts/doctor.py
```

Read the output. Each finding has a code, scope (task ID or `global`), severity, and a recovery hint.

### 2. Default mode — report and stop

Print a one-line summary: `Doctor: <N> findings — <BLOCK> BLOCK, <WARN> WARN, <INFO> INFO.` Then yield to the operator.

If `--json` was passed, print the JSON payload from `python3 scripts/doctor.py --json` and exit.

### 3. `--fix` mode — interactive repair

For each finding, in BLOCK → WARN → INFO order, prompt:

```
[<severity>] <code> (<scope>)
  <message>

  Recovery: <hint>

  Apply? (y/n/skip-rest)
```

Apply per code:

- **`untracked-sidecar`** — ask whether to (a) commit it now, (b) delete it, or (c) skip. On (a): ask for the rationale (scaffold vs. recovered) and stage `git add .taskstate/<ID>.json`. Defer the actual commit to the end so multiple findings batch into one chore commit.
- **`untracked-decision`** — same shape: commit (with the operator providing an ADR number / chore subject) vs. delete vs. skip.
- **`dirty-product-code-on-main`** — never auto-fix. Print the path and the file's diff against HEAD; ask the operator whether to (a) revert with `git checkout -- <path>`, (b) leave it (likely they'll move it into a worktree manually), or (c) skip.
- **`masterplan-symbol-drift`** — offer to run `python3 scripts/sync-masterplan-status.py` once at the end (collect into a single-pass refresh). This is a manual operation, so prompt explicitly.
- **`stranded-inflight`** — never auto-execute the next ritual step. Print the suggestion (`/walk <ID>` or `/ship <ID>`) and the worktree path; let the operator drive.
- **`inflight-without-worktree`** — print suggested recovery (`/build --adopt <ID>` or roll back the sidecar). Do not execute.
- **`orphaned-worktree`** — only safe action is `git worktree remove <path>`; ask before doing.
- **`terminal-without-commit`** — never auto-fix. Print the suggested investigation (reflog / dangling). This is a load-bearing manual review.

### 4. Apply the batched commit (if `--fix` and any items chose "commit")

If the operator approved any sidecar / decision commits, apply them as a single chore commit on main:

```bash
git add <staged paths>
git commit -m "$(cat <<'EOF'
chore: doctor cleanup — <short summary>

Findings resolved:
- <code> <scope>: <action taken>
- ...

EOF
)"
```

If the only repair was running `sync-masterplan-status.py`, that script's own commit handling applies (it just rewrites MASTERPLAN.md — operator chooses when to commit).

### 5. Re-audit

Run `python3 scripts/doctor.py` again and report the new finding count. If the operator declined fixes, the count is unchanged — that's expected.

## Report

```
Doctor pass — <N before> findings → <N after> findings.

Resolved:
  - <code> <scope>: <one-line action>

Skipped (operator declined or deferred):
  - <code> <scope>: <reason>

Outstanding (not auto-fixable):
  - <code> <scope>: <next step>
```

## Never

- Never run `git checkout --` or `rm` without operator confirmation per item.
- Never invoke `/build --adopt`, `/walk`, or `/ship` from inside `/doctor`. Surface the suggestion only.
- Never modify a sidecar status field directly. The ritual writes status; `/doctor` only flags drift.
- Never modify MASTERPLAN.md outside of running `scripts/sync-masterplan-status.py` (and only with operator consent).
- Never delete a worktree without running `git worktree list` first to confirm nothing in-flight is held there.

## Exit codes

- 0 — no drift
- 1 — BLOCK or WARN findings
- 2 — INFO findings only
- 3 — script error (MASTERPLAN missing, etc.)

`/doctor` is safe to wire into a future pre-push hook on `main` (`scripts/doctor.py --quiet` exits with the appropriate code) but that wiring is not part of this command.
