---
description: Run all quality gates for the given task — lint, typecheck, test, build. Usage — /check <TASK-ID>
argument-hint: <TASK-ID>
---

You are running quality gates for task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md)).

## Preflight — must run inside the task's worktree

1. Read `.taskstate/$ARGUMENTS.json` from the main checkout.
2. Confirm `pwd` ends in the sidecar's `worktree` (e.g. `.worktrees/<id-lowercase>`). Else stop: "`/check` must run inside the task's worktree. cd `<worktree>` and retry."
3. Confirm `git branch --show-current` matches the sidecar's `branch`. Else stop.
4. Confirm sidecar `status: walked` (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md) — `/walk` runs before `/check`). `built` → run `/walk <ID>` first. `in-progress` → build not finished. `reviewed`/`shipped` → already past `/check`. Stop on anything other than `walked`.

Do not change code unless a gate fails and the fix is obviously trivial (formatting, import order, unused variable). Non-trivial failures → stop and report.

## Gates — run in order, stop on first failure

### 0. Prefilter — diff-aware gate selection (per [ADR 0019](../../decisions/0019-diff-aware-check-gate-selection.md))

Compute `LIGHT` from the diff against `main`. Heavy gates (typecheck, tests, build) consult it; cheap gates (format, lint) and the task-specific gate always run.

```bash
CHANGED_CODE=$(git diff --name-only main...HEAD \
  | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|go|py)$' || true)
CHANGED_MIGRATIONS=$(git diff --name-only main...HEAD -- supabase/migrations/ || true)
CHANGED_SCHEMA_SQL=$(git diff --name-only main...HEAD -- '*.sql' ':!supabase/migrations/' || true)

LIGHT=0
if [ -z "$CHANGED_CODE" ] && [ -z "$CHANGED_MIGRATIONS" ] && [ -z "$CHANGED_SCHEMA_SQL" ]; then
  LIGHT=1
fi
```

Under `LIGHT=1`, heavy gates emit `"skip"` in `gate-summary.json` with `"reason": "light mode — no code changed"`, and the file carries top-level `"light": true` so `/review` surfaces the mode to the reviewer. Under `LIGHT=0` behaviour is unchanged from [ADR 0013](../../decisions/0013-local-check-parity.md). See ADR 0019 for the full gate matrix and "what counts as code" regex (deliberate: `.sql` outside migrations triggers full mode via `CHANGED_SCHEMA_SQL`; `.sh` covered by Format+Lint; `package.json`/`pnpm-lock.yaml` intentionally not code).

### 1. Format

```bash
pnpm format:check
```

### 2. Lint

```bash
pnpm lint         # JS/TS via turbo (eslint + next lint)
pnpm py:lint      # ruff check + ruff format --check in each service's venv
```

`py:lint` skips cleanly when a service's `.venv` is absent (F-16 / ADR 0013); bootstrap with `pnpm py:bootstrap` to activate locally. Go lint (`gofmt -l`) runs in CI only (`.github/workflows/ci.yml`).

### 3. Typecheck

```bash
pnpm typecheck
```

TypeScript only. Python type-checking is opt-in per service (`mypy` if configured).

**Skip when `LIGHT=1`** — emit `{ "typecheck": "skip", "reason": "light mode — no code changed" }`.

### 4. Tests

```bash
pnpm test         # JS/TS via turbo
pnpm py:test      # pytest in api + agent
pnpm go:test      # go test ./... in gateway
```

Run the subset relevant to changed files if the full run exceeds 2 min: `turbo test --filter='...[HEAD^1]'`.

**Skip when `LIGHT=1`** — emit `{ "tests": "skip", "reason": "light mode — no code changed" }` and omit `coverage.json` (empty coverage is misleading).

### 5. Build

```bash
pnpm build        # turbo build
pnpm go:build     # Go binary
```

**Skip when `LIGHT=1`** — emit `{ "build": "skip", "reason": "light mode — no code changed" }`.

### 6. Task-specific checks

Based on the task ID prefix:

- **F-\***: run `pnpm dev` briefly; hit `/health` endpoints.
- **SC-\***: `pnpm check:sc` — boots local Supabase (if down), runs `supabase db reset` + `supabase test db` (pgTAP). Prereq: Docker Desktop + Supabase CLI (see README.md "Prerequisites"). Missing prereq exits with a one-line remediation — that's `fail`, not `skip`. Per ADR 0013, this gate should be `pass` from SC-4 onwards — `skip` is a regression flag.
- **AU-\***: hit auth endpoint with a test email; confirm magic-link flow end-to-end.
- **LI-\***: Playwright screenshot-test against mobile viewport; compare structure to `../prototypes/sally-mvp-prototype.jsx`.
- **AG-\***: exercise the LangGraph flow with a synthetic buyer message; confirm LangSmith trace tags; for negotiation tasks, run `apps/agent/tests/test_isolation.py`.
- **CH-\***: confirm Supabase Realtime subscription fires; for FashionID, confirm `recompute_fashionid()` runs correctly.
- **BP-\***: no product surface — manually verify against the row's acceptance criterion (re-run touched `.claude/commands/*.md` snippets literally, diff `.claude/agents/*.md` edits). If the row touches `scripts/py-*.sh`, `scripts/__tests__/*.sh`, or sibling shell tooling, run `pnpm test:scripts` (per BP-2). Standard gates still apply to changed scripts/config.

## Emit artifacts for downstream rituals

Drop machine-readable artifacts under `.taskstate/artifacts/<ID>/` (gitignored):

- `coverage.json` — merged coverage (`pnpm test -- --coverage --coverageReporters=json-summary` for JS/TS; `pytest --cov --cov-report=json` for Python; `go test -coverprofile` + `go tool cover -func | tail -1` for Go). Include `{ "lines_pct": <number>, "per_package": {...} }`. Record the gap if <80% — reviewer decides blocking. **Omit entirely when `LIGHT=1`**.
- `screenshots/` — for **LI-\*** and **CH-\***, Playwright mobile-viewport PNGs keyed by component/page; one per screen touched.
- `gate-summary.json` — `{ "light": <bool>, "format": …, "lint": …, "typecheck": …, "tests": …, "build": …, "task_specific": … }` where each gate is `"pass" | "fail" | "skip"` with a short message. Skipped gates under light mode carry `"reason": "light mode — no code changed"`; pre-existing `skip` semantics (e.g. `py:test` without venv) unchanged with their own reasons.

## Output

```
### Check results — <ID>

Mode: full | light (diff touched only markdown/json/yaml — heavy gates skipped per ADR 0019)

| Gate | Status |
|------|--------|
| Format | ✓ / ✗ |
| Lint | ✓ / ✗ |
| Typecheck | ✓ / ✗ / — (skipped: light mode) |
| Tests | ✓ / ✗ (<n passed / <n failed>) / — (skipped: light mode) |
| Build | ✓ / ✗ / — (skipped: light mode) |
| Task-specific | ✓ / ✗ |

<If any ✗: detail the failure and whether it's safe to proceed to /review, or needs more work.>
```

## Never

- Never flip sidecar status on `/check` — status only changes on `/build` end, `/walk`, `/review`, and `/ship`.
- Never commit during `/check`. If fixing a trivial failure, commit as `chore: fix <lint|format|…> in <ID>` and re-run.
- Never leave the worktree. All gates run inside `.worktrees/<id-lowercase>/`.
- If tests are flaky, run 3×. Still flaky → fail. Flaky tests are real failures.
