---
description: Run all quality gates for the given task — lint, typecheck, test, build. Usage — /check <TASK-ID>
argument-hint: <TASK-ID>
---

You are running quality gates for task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md)).

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Preflight — must run inside the task's worktree

1. Read `.taskstate/$ARGUMENTS.json` from the main checkout.
2. Confirm `pwd` ends in the sidecar's `worktree` (e.g. `.worktrees/<id-lowercase>`). Else stop: "`/check` must run inside the task's worktree. cd `<worktree>` and retry."
3. Confirm `git branch --show-current` matches the sidecar's `branch`. Else stop.
4. Confirm sidecar `status: walked` (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md) — `/walk` runs before `/check`). `built` → run `/walk <ID>` first. `in-progress` → build not finished. `reviewed`/`shipped` → already past `/check`. Stop on anything other than `walked`.

Do not change code unless a gate fails and the fix is obviously trivial (formatting, import order, unused variable). Non-trivial failures → stop and report.

## Gates — run in order, stop on first failure

### 0. Prefilter — diff-aware gate selection

Compute `LIGHT` from the diff against `main`. Heavy gates (typecheck, tests, build) consult it; cheap gates (format, lint) and the task-specific gate always run.

```bash
CHANGED_CODE=$(git diff --name-only main...HEAD \
  | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|go|py|rb|java|kt|swift|rs|php|cs)$' || true)
CHANGED_SCHEMA_SQL=$(git diff --name-only main...HEAD -- '*.sql' || true)

LIGHT=0
if [ -z "$CHANGED_CODE" ] && [ -z "$CHANGED_SCHEMA_SQL" ]; then
  LIGHT=1
fi
```

Heavy gates emit `"skip"` in `gate-summary.json` with `"reason": "light mode — no code changed"` when `LIGHT=1`, and the file carries top-level `"light": true` so `/review` surfaces the mode to the reviewer. Light mode covers diffs that touch only documentation, configuration, or non-code assets — projects can extend the regex above to match their stack.

Each heavy gate may opt out of light-mode skipping by setting `gates.<name>.light_eligible: false` in `ritual.config.yaml`. Check via:

```bash
bash .claude/ritual/scripts/ritual-config.sh gate.light_eligible <gate-name>
```

### 1. Format

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd format)
```

### 2. Lint

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd lint)
```

### 3. Typecheck

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd typecheck)
```

**Skip when `LIGHT=1`** (and `gate.light_eligible typecheck` is `true`) — emit `{ "typecheck": "skip", "reason": "light mode — no code changed" }`.

### 4. Tests

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd test)
```

**Skip when `LIGHT=1`** (and `gate.light_eligible test` is `true`) — emit `{ "tests": "skip", "reason": "light mode — no code changed" }` and omit `coverage.json` (empty coverage is misleading).

### 5. Build

```bash
$(bash .claude/ritual/scripts/ritual-config.sh gate.cmd build)
```

**Skip when `LIGHT=1`** (and `gate.light_eligible build` is `true`) — emit `{ "build": "skip", "reason": "light mode — no code changed" }`.

### 6. Task-specific checks

Per the task's prefix in `ritual.config.yaml`, run the gate command from `gates.task_specific.by_prefix.<PREFIX>`:

```bash
TASK_PREFIX="$(echo "$ARGUMENTS" | cut -d- -f1)"
TASK_GATE="$(bash .claude/ritual/scripts/ritual-config.sh prefix.task_specific "$TASK_PREFIX")"
if [ -n "$TASK_GATE" ]; then
  eval "$TASK_GATE"
fi
```

If empty, no task-specific gate runs. Projects define per-prefix gate commands in `ritual.config.yaml` under `gates.task_specific.by_prefix` — typically things like database-migration smoke tests, auth flow probes, screenshot diffs against the prototype, agent trace assertions, etc.

## Emit artifacts for downstream rituals

Drop machine-readable artifacts under `.taskstate/artifacts/<ID>/` (gitignored):

- `coverage.json` — merged coverage from the project's test runner. Include `{ "lines_pct": <number>, "per_package": {...} }`. Record the gap if below the project's coverage target — reviewer decides blocking. **Omit entirely when `LIGHT=1`**.
- `screenshots/` — for UX-prefixed tasks, viewport PNGs keyed by component/page; one per screen touched.
- `gate-summary.json` — `{ "light": <bool>, "format": …, "lint": …, "typecheck": …, "tests": …, "build": …, "task_specific": … }` where each gate is `"pass" | "fail" | "skip"` with a short message. Skipped gates under light mode carry `"reason": "light mode — no code changed"`; pre-existing `skip` semantics (e.g. test runner without venv) unchanged with their own reasons.

## Output

```
### Check results — <ID>

Mode: full | light (diff touched only markdown/json/yaml — heavy gates skipped)

| Gate | Status |
|------|--------|
| Format | pass / fail |
| Lint | pass / fail |
| Typecheck | pass / fail / skip (light mode) |
| Tests | pass / fail (<n passed / <n failed>) / skip (light mode) |
| Build | pass / fail / skip (light mode) |
| Task-specific | pass / fail |

<If any fail: detail the failure and whether it's safe to proceed to /review, or needs more work.>
```

## Never

- Never flip sidecar status on `/check` — status only changes on `/build` end, `/walk`, `/review`, and `/ship`.
- Never commit during `/check`. If fixing a trivial failure, commit as `chore: fix <lint|format|…> in <ID>` and re-run.
- Never leave the worktree. All gates run inside `.worktrees/<id-lowercase>/`.
- If tests are flaky, run 3×. Still flaky → fail. Flaky tests are real failures.
