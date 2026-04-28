---
description: Human-in-the-loop walkthrough of a built task before /check + /review. Usage — /walk <TASK-ID>
argument-hint: <TASK-ID>
---

You are driving a **human-in-the-loop walkthrough** for task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md) + [ADR 0007](../../decisions/0007-human-in-the-loop-walk.md), repositioned by [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md)). The operator is the tester. Your job: set the stage, read the journey steps aloud, collect pass/fail notes, persist.

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## When /walk runs

`/walk` runs **immediately after `/build`, before `/check` and `/review`** (per ADR 0037). The operator iterates `/build`-then-`/walk` against the worktree dev server until visually satisfied; only then do `/check` and `/review` run on the locked-in code.

- **UX prefixes** (per `prefix.ux: true` in `ritual.config.yaml`) — full walkthrough; multi-attempt iteration is supported via the `walk_notes[]` array.
- **Non-UX prefixes** (per `prefix.ux: false` or absent) — auto-skip flip with a synthetic `walk_notes` entry. No dev server, no operator action.

Detect via:

```bash
TASK_PREFIX="$(echo "$ARGUMENTS" | cut -d- -f1)"
IS_UX="$(bash .claude/ritual/scripts/ritual-config.sh prefix.ux "$TASK_PREFIX")"
```

## Preflight — must run inside the task's worktree

1. Read `<repo-root>/.taskstate/$ARGUMENTS.json`. Compute `IS_UX` as above.
2. Confirm `pwd` ends in the sidecar `worktree`; `git branch --show-current` matches `branch`. Otherwise stop.
3. Handle sidecar status:
   - `in-progress` → run `/build` first. Stop.
   - `built` → proceed below (auto-skip for non-UX, full walkthrough for UX).
   - `walked`:
     - Non-UX prefix → print `Already walked — run /check <ID>.` and exit cleanly. Expected post-skip state.
     - UX prefix → already walked; the operator may iterate by editing code in the worktree and re-running `/walk` to append a fresh attempt (see "Iterating after walked"); otherwise proceed to `/check`.
   - `reviewed` / `shipped` → already past walk; stop.

## Auto-skip path (non-UX prefix at `built`)

For non-UX prefixes the human walkthrough adds nothing (no user-facing surface). Walk auto-skips:

1. Flip sidecar → `status: walked`; append one attempt object to `walk_notes`:
   ```json
   {
     "attempt": <prior_attempts.length + 1>,
     "at": "<ISO-8601 timestamp>",
     "steps": [
       { "step": "n/a — non-user-facing", "result": "skip", "note": "<prefix> does not require UX walkthrough per ADR 0037" }
     ]
   }
   ```
   Refresh `updated_at`.
2. Commit as `chore: walk skipped <ID>` with the trailer block.
3. Tell user: `No walkthrough needed for <prefix>. Run /check <ID> next.` Stop.

## Full walkthrough (UX prefix at `built`)

### 1. Resolve the journey

- Read the PRD section(s) referenced by the task's `PRD` column in `MASTERPLAN.md` (`{{paths.prd}}`).
- For each user-story or acceptance-criterion ID listed there, derive the user-visible journey step(s) the diff is meant to satisfy.
- For prefixes that have a non-negotiable rules section in `.claude/ritual/reviewer.project.md`, also load any adversarial probes the task should resist (e.g. prompt-injection, scope-bypass, identity-leak attempts). Adversarial probes are project-defined.

### 2. Spin up the surface

- Dev server runs **from this worktree**, not the main checkout:

  ```bash
  $(bash .claude/ritual/scripts/ritual-config.sh get walk.dev_server_cmd)
  ```

  Print the resulting `http://localhost:<port>` URL (port from `walk.default_port` in `ritual.config.yaml`).
- Print the mobile test URL if applicable + reminder: "Open in Chrome mobile emulation at the project's target viewport — or scan a QR with a real device on the same network."

The dev server compiles on-the-fly; it does **not** require a green `/check` to start. If a typecheck or lint error prevents compilation, the operator sees it in the terminal/browser, fixes the file in the worktree, and re-runs `/walk` (see "Iterating after walked" below for the loop semantics).

### 3. Present the checklist

Numbered, one-step-per-line checklist from the journey. Each line = one concrete user action + observable pass criterion. Example:

```
1. Open the relevant route on the target viewport.
   Expect: components render with the design-system tokens (colors, radii, spacing) — no invented values.
2. Tap an interactive element.
   Expect: navigation/state change matches the prototype reference; no flash of unstyled content.
3. Observe voice on user-facing copy.
   Expect: matches the project's voice rules in {{paths.design_system}}/README.md.
```

For prefixes with adversarial probes, append the probes as numbered steps with the exact input and expected behavior.

### 4. Collect results

Ask the operator for one line per step:

```
1. pass
2. fail — color was off-token; expected #XXXXXX, got #YYYYYY
3. pass
```

Accept `pass`, `fail`, `skip`. Free-text after `—` is the note. Wait for the full list.

### 5. Persist

Write into `.taskstate/<ID>.json`'s `walk_notes` array. Each `/walk` run appends exactly one attempt object — never edit prior attempts in place:

```json
"walk_notes": [
  {
    "attempt": 1,
    "at": "2026-04-19T10:03:17Z",
    "steps": [
      { "step": "1. Open the relevant route.", "result": "pass", "note": "" },
      { "step": "2. Tap an interactive element.", "result": "fail", "note": "color was off-token" },
      { "step": "3. Voice on user-facing copy.", "result": "pass", "note": "" }
    ]
  }
]
```

`attempt` = `prior_attempts.length + 1`. `at` is ISO-8601 captured when the operator submits. Re-runs push a new object; `/ship` copies the full array into BUILDLOG so "felt off first time, passed second time" stays visible.

### 6. Decide

- **All pass (or only `skip`):** flip sidecar → `status: walked`; commit as `chore: walked <ID>` with the trailer; tell user `Walked. Run /check <ID> next (per ADR 0037 — gates run on the walked diff).`
- **Any fail:** keep sidecar at `built`; summarize failures; tell user `Walk failed on steps <list>. Edit files in the worktree to fix, then re-run /walk <ID> for another attempt.` Do not auto-fix.

## Iterating after walked

Walk approval matches the diff that ships (per ADR 0037). If the operator wants to make further code changes after a successful walk:

1. Edit files in the worktree as usual.
2. Re-run `/walk <ID>`. Per the preflight rules, a UX prefix at `walked` may re-walk to append a fresh attempt — operator confirms intent ("re-walk after edits? y/n") to avoid accidental re-walks. On confirm, treat as a fresh walkthrough: collect a new `walk_notes` attempt, all-pass keeps `walked`, any-fail flips sidecar back to `built`.
3. When satisfied, run `/check <ID>` → `/review <ID>` → `/ship <ID>`.

If `/auto`'s auto-fix loop mutates code after a `walked` flip (per [ADR 0031](../../decisions/0031-automated-ritual-mode.md) + ADR 0037 amendment), it reverts the sidecar to `built` automatically and writes a `stale` step entry — the operator must re-walk. `/walk` itself never writes the `stale` entry; only `/auto` does, when its fix invalidates a prior approval.

## Never

- Never edit prior `walk_notes` attempts — a new run pushes a fresh entry with `attempt` index and ISO timestamp, so "felt off first time, passed second time" is visible in BUILDLOG.
- Never flip `status: walked` if any result is `fail`.
- Never skip the walkthrough for UX prefixes. If a step is genuinely un-testable, use `skip` with a note — never `pass`.
- Never run `/walk` outside the task's worktree. Dev server must exercise _this branch's_ code, not `main`.
- Never write a `stale` step entry from `/walk` itself — that marker is reserved for `/auto`'s post-walk drift detection.
- For prefixes with adversarial probes: the operator performs them in the live UI. Do not simulate via curl — the point is to see what the user sees.
