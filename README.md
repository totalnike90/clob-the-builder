# clob-the-builder

A portable, opinionated **task-execution ritual for Claude Code projects**: slash commands, sidecar state, gated quality checks, and a human-in-the-loop walkthrough. Packaged so any new repo can adopt the discipline in two commands.

```bash
git clone https://github.com/totalnike90/clob-the-builder.git ~/code/clob-the-builder
cd <your-project>
bash ~/code/clob-the-builder/install.sh
# then, inside Claude Code:
/plan-init docs/PRD.md
```

That's it. You're now running the ritual.

---

## About

Built by **Jerry Neo** ([@totalnike90](https://github.com/totalnike90)).

After more than 1000 AI-assisted tasks on 4 production builds, I kept watching discipline drift faster than capability scaled. `clob-the-builder` is the smallest set of constraints I found that keeps the work coherent, reviewable, and revertable. Universal core extracted; project specifics stay in your repo.

---

## What you get

A complete task lifecycle:

```
/plan-init        # one-time: scaffold MASTERPLAN.md from your PRD
   ↓
/plan-next        # pick the next unblocked task
   ↓
/build <ID>       # implement on an isolated worktree
   ↓
/walk <ID>        # human walks through the change (UX prefixes only)
   ↓
/check <ID>       # format · lint · typecheck · test · build · task-specific
   ↓
/review <ID>      # independent reviewer subagent against the PRD
   ↓
/ship <ID>        # squash-merge under a lock; one task = one commit
```

Plus orchestrators (`/auto`, `/batch`, `/blitz`), audit (`/doctor`), fast-path (`/patch`), and a follow-up triage register.

## Why

Most AI-assisted coding workflows fall apart on the same things: untracked work, drift between intent and implementation, scope creep, no audit trail, broken reverts. `clob-the-builder` enforces:

- **One task = one branch = one worktree = one squash commit.** Reverts are always 1:1.
- **Sidecar state.** `.taskstate/<ID>.json` is the source of truth. Status lattice: `todo < planned < in-progress < built < walked < reviewed < shipped`.
- **Walk before gates.** Human verifies UX *before* compute is spent on gates and review.
- **Follow-up triage register.** Every reviewer suggestion gets a disposition: resolved, promoted, folded, or dropped.
- **Trailers required.** Every commit carries `Task: <ID>` so `git log` is queryable forever.

---

## How `/plan-init` works

`/plan-init <PRD-PATH>` is the genesis command. It runs once per project, after `bash install.sh`. It:

1. Reads your PRD (markdown, plain text, or PDF via `pdftotext`).
2. Optionally reads UI mockups (`--screens <DIR>`).
3. Dispatches the `masterplan-scaffolder` subagent, which proposes:
   - **A prefix taxonomy** (e.g., `FE-*` Frontend, `BE-*` Backend, `INF-*` Infra) with rationale tied to PRD sections.
   - **A task list** under each prefix with deps and PRD-refs.
   - **Non-negotiable rules** drawn from the PRD's normative language ("must", "never", "shall").
4. Displays the proposal. You confirm `[y]es / [e]dit / [n]o`.
5. On `y`: writes `MASTERPLAN.md`, populates `prefixes:` in `ritual.config.yaml`, generates `.claude/ritual/reviewer.project.md`, creates per-task `.taskstate/<ID>.json` sidecars, and commits one `chore: scaffold masterplan from <PATH>` commit.

Until `/plan-init` runs, all task-picking commands (`/plan-next`, `/build`, `/auto`, etc.) stop with: *"Run `/plan-init <PRD-path>` first."*

---

## Orchestrators

The seven core commands above run the ritual one task at a time, manually. Six **orchestrators** cover everything else: automation, parallelism, live-iteration shortcuts, audit, and follow-up reconciliation. None of them are required — the ritual works fine without them — but each removes specific friction once you outgrow the manual loop.

### `/auto [<ID>] [--continue] [--chain]` — drive a single task end-to-end

Runs `/build → /walk → /check → /review → /ship` for one task without you typing each step. Auto-fixes failed gates and reviewer findings within bounded retry budgets (default 3 retries on `/check`, 2 on `/review`, ≤20-line auto-fix diffs). Pauses only at human gates: `/walk` for UX prefixes, and `/ship` Step 7.5 if out-of-scope follow-ups need disposition.

```bash
/auto FE-1                 # one task end-to-end
/auto                      # picks the next eligible task itself
/auto --continue           # resumes the most recent in-flight task
/auto FE-1 --chain         # after FE-1 ships, picks the next eligible and continues
```

When to use: green-path tasks where you want to spend cycles reviewing the diff, not typing commands. Skip when you expect manual intervention or the task spans many surfaces.

Auto-fix discipline: any code-mutating fix after `walked` reverts the sidecar to `built` and re-runs `/walk` so the operator's approval always matches what ships. Budget exhaustion stalls the task; you escalate to manual `/check`.

### `/batch <ID1> <ID2> [...] [--limit N] [--phase=build|gates]` — parallel ritual

Runs `/build` (then optionally `/check + /review`) in parallel across multiple tasks, in two waves bracketing the serial walk gate. Wave 1 dispatches `/build` in parallel worktrees; you walk each task serially (auto-skipped for non-UX prefixes); wave 2 dispatches `/check + /review` in parallel.

```bash
/batch FE-1 FE-2 BE-3                     # full two-phase batch
/batch FE-1 FE-2 BE-3 --phase=build       # just the build wave
/batch FE-1 FE-2 BE-3 --phase=gates       # just the gates wave (after walks)
/batch FE-1 FE-2 BE-3 --limit 2           # cap concurrent worktrees
```

When to use: a backlog of small independent tasks that share no files. Skip when tasks have overlapping surfaces (collisions), or when one task's output unblocks another (use `/auto --chain` instead).

`/ship` stays serial and human-gated — `/batch` does not ship for you.

### `/blitz [--i-know]` — session-level bypass for live iteration

Bypasses `/walk` and `/review` for an entire session. You iterate on a `blitz/<slug>` branch, run cheap gates only (format + lint + typecheck — no tests, no build, no review subagent), and at land time the session lays down one squash commit per task ID directly on `main`. The 1:1 commit-to-revert invariant is preserved.

```bash
/blitz                     # start a blitz session
# ...iterate, commit per task...
/ship blitz <slug>         # land all tasks as separate squash commits
```

When to use: rapid prototyping, experimenting against a dev server, or focused multi-feature sessions where the operator personally tests every change in-browser. The audit trail records every blitzed task as `status: blitzed` so the bypass is visible in BUILDLOG.

`--i-know` is required when the session touches risky surfaces (migrations, infra files, or any path listed in `blitz.risky_surfaces` in `ritual.config.yaml`). It's an explicit opt-in so foot-guns are loud.

### `/patch <TASK-ID>` — fast-path for trivial changes

Skips worktree creation and the reviewer subagent for prefixes flagged with `fast_path: true` in `ritual.config.yaml`. The change lands directly via a single squash commit. Suitable for one-line copy fixes, dependency bumps, or config tweaks where the diff is obviously safe.

```bash
/patch SC-12               # only valid for prefixes with fast_path: true
```

When to use: trivial changes you'd otherwise feel silly cycling through `/build → /walk → /check → /review → /ship`. Skip the moment the change touches more than a few lines or affects user-facing behavior.

Each prefix's `fast_path_forbidden_paths` blocks the fast-path when a forbidden path is touched (e.g., migrations on a SC-* prefix that's otherwise fast-path-eligible).

### `/triage <TASK-ID> | --all` — reconcile shipped follow-ups

Walks a shipped task's BUILDLOG `Follow-ups:` bullets and ensures each has a disposition (`resolved`, `promoted`, `folded`, or `dropped`) recorded in the sidecar's `follow_ups[]` array. `/ship` already runs Step 7.5 triage at land — `/triage` is for retroactive cleanup when bullets accumulated unprocessed (e.g., during a `/blitz` session).

```bash
/triage FE-1               # reconcile a single shipped task
/triage --all              # backfill every shipped task with unregistered bullets
```

When to use: after `/plan-next` warns about unregistered follow-ups, or when migrating from a project that wasn't using the disposition register. The script is idempotent — re-running on a fully-triaged task is a no-op.

### `/doctor [--fix]` — state-drift audit

Cross-checks every ritual surface (MASTERPLAN, sidecars across main and every active worktree, `git worktree list`, branch refs, recent `git log`, `git status`) for drift. Reports findings grouped by severity. Read-only by default.

```bash
/doctor                    # human-readable audit
/doctor --json             # machine-readable findings
/doctor --fix              # interactive repair (each fix prompts y/n)
```

When to use: weekly hygiene, after a power loss or session crash, or when something feels "off" (a worktree that shouldn't exist, a sidecar status that doesn't match git, a stranded branch). Common findings:

- `untracked-sidecar` — a sidecar in `.taskstate/` not staged in git
- `stranded-inflight` — worktree at `reviewed` but main sidecar still `todo` (a `/ship` that didn't complete)
- `dirty-product-code-on-main` — uncommitted changes on `main` from outside the ritual
- `multi-attempt-walk` — tasks needing ≥3 walk attempts (signals UX or tooling friction)

The `--fix` flag is interactive: every repair is prompt-confirmed so the auditor never silently rewrites state.

---

## Configuration

Single project file: `ritual.config.yaml`. Generated by `install.sh`, populated further by `/plan-init`.

```yaml
ritual_version: 0.1.0

paths:
  prd: docs/PRD.md
  design_system: design/
  prototypes: design/prototypes/
  masterplan: MASTERPLAN.md
  buildlog: BUILDLOG.md
  followups: FOLLOWUPS.md
  taskstate: .taskstate/
  worktrees: .worktrees/

git:
  main_branch: main
  branch_pattern: "task/{id_lc}-{slug}"
  worktree_pattern: ".worktrees/{id_lc}/"

commit:
  trailer_keys: [Task]
  squash_only: true

# Populated by /plan-init from your PRD.
prefixes:
  FE: { name: Frontend, ux: true,  gates: [format, lint, typecheck, test, build] }
  BE: { name: Backend,  ux: false, gates: [format, lint, typecheck, test] }

# Filled by your stack preset.
gates:
  format:    { cmd: "pnpm format:check", light_eligible: false }
  lint:      { cmd: "pnpm lint",         light_eligible: false }
  typecheck: { cmd: "pnpm typecheck",    light_eligible: true  }
  test:      { cmd: "pnpm test",         light_eligible: true  }
  build:     { cmd: "pnpm build",        light_eligible: true  }

retry_budgets:
  check: 3
  review: 2
  auto_fix_max_lines: 20

walk:
  dev_server_cmd: "pnpm dev"
  default_port: 3000

reviewer:
  rules_file: .claude/ritual/reviewer.project.md
  non_negotiables: []

hooks:
  pre_tool_use: [guard-main]
  post_tool_use: [remind-non-negotiables]
```

### Stack presets

`install.sh` auto-detects your stack and seeds `gates:` accordingly:

| Preset | Detected by | Gate flavor |
|---|---|---|
| `pnpm-monorepo` | `pnpm-workspace.yaml`, or `package.json` with `"workspaces"` | `pnpm format:check`, `pnpm lint`, etc. |
| `npm-single` | `package.json` | `npm run format:check`, `npm run lint`, etc. |
| `python-uv` | `pyproject.toml` or `uv.lock` | `uv run ruff format --check`, `uv run pytest`, etc. |
| `go-modules` | `go.mod` | `gofmt`, `go vet`, `go test`, etc. |
| `blank` | (fallback) | empty strings — wire up after install |

Override at install with `--preset <name>`.

### Runtime config reads

Slash commands read config values via `bash .claude/ritual/scripts/ritual-config.sh <subcommand>`. Subcommands:

- `get <key.path>` — dotted-path value, e.g. `paths.prd`
- `gate.cmd <name>` — gate command for a named gate
- `prefix.list` — space-separated prefix IDs
- `prefix.ux <P>` — `true` or `false`
- `prefix.gates <P>` — gates list for a prefix
- `has-prefixes` — exits 0 if any prefix configured, else exits 1 (the empty-prefix preflight)

This means you can swap your test runner from `npm test` to `vitest run` by editing `ritual.config.yaml` — the commands themselves don't need to change.

---

## What the ritual contains

```
.claude/ritual/                  installed core (don't edit by hand)
├── commands/                    14 slash commands
│   ├── plan-init.md             genesis: scaffold MASTERPLAN from PRD
│   ├── plan-next.md             pick next unblocked task
│   ├── plan-build.md            pre-build plan gate (UX-prefix tasks)
│   ├── build.md                 implement on isolated worktree
│   ├── walk.md                  human-in-the-loop UX walkthrough
│   ├── check.md                 quality gates (format, lint, typecheck, test, build)
│   ├── review.md                independent reviewer subagent
│   ├── ship.md                  squash-merge with follow-up triage
│   ├── auto.md                  drive a single task end-to-end
│   ├── batch.md                 parallel ritual across multiple tasks
│   ├── blitz.md                 session-level fast-path bypass
│   ├── patch.md                 trivial-change fast-path
│   ├── triage.md                reconcile shipped follow-ups
│   └── doctor.md                state-drift audit
├── agents/                      4 subagents
│   ├── reviewer.md              independent diff reviewer
│   ├── spec-checker.md          PRD section conformance check
│   ├── visual-diff.md           UI structural + token diff
│   └── masterplan-scaffolder.md proposes prefixes/tasks from PRD
├── scripts/                     7 portable scripts
│   ├── ritual-config.sh         YAML config reader
│   ├── slice-buildlog.py        O(1) BUILDLOG slice by task ID
│   ├── regen-followups.py       generate FOLLOWUPS.md from sidecars
│   ├── doctor.py                state auditor
│   ├── propagate-env-to-worktree.sh  env file copy helper
│   ├── backfill-buildlog-anchors.py
│   └── sync-masterplan-status.py
├── hooks/                       2 hooks
│   ├── guard-main.sh            block destructive/non-ritual git ops
│   └── remind-non-negotiables.sh PostToolUse path-based reminder
└── reviewer.project.md          your project's non-negotiables (after /plan-init)
```

`.claude/{commands,agents,hooks}` are symlinks into `.claude/ritual/`, so Claude Code's discovery finds them.

---

## FAQ

**Why a separate `clob-the-builder` repo? Why not just copy the files?**
Because the ritual evolves. Pulling upstream improvements is a `git pull` away from re-running `install.sh`. Copying drifts.

**Can I retrofit `clob-the-builder` into an existing project?**
Yes. Run `bash install.sh` from the project root; it detects existing `MASTERPLAN.md` / `.taskstate/` / `.claude/commands/` and renders a `ritual.config.yaml.proposed` for you to inspect. Re-run with `--apply` once the proposed config looks right.

**What if my project doesn't fit any preset?**
Pick `blank` and edit `ritual.config.yaml`'s `gates:` block manually. The commands work as long as `gate.cmd <name>` returns something runnable.

**Does the reviewer agent know about my project's rules?**
Yes — `/plan-init` extracts non-negotiable rules from your PRD and writes them to `.claude/ritual/reviewer.project.md`. The reviewer reads that file at every `/review`.

**What happens to `/walk` if my project has no UX?**
For prefixes where `ux: false` in `ritual.config.yaml`, `/walk` auto-skips with a synthetic note. UX-prefix tasks (`ux: true`) require manual operator approval before `/check` can run.

**Can I extend the ritual with my own commands?**
Yes. Drop your custom `.md` command files into `.claude/commands/` directly (not the symlinked `ritual/` dir). They live alongside the installed ones.

**How do I uninstall?**
`bash <clob-the-builder>/uninstall.sh` from your project root. It removes `.claude/ritual/`, the symlinks, and the ritual block from `CLAUDE.md` and `.claude/settings.json`. It **preserves** project history: `MASTERPLAN.md`, `BUILDLOG.md`, `FOLLOWUPS.md`, `.taskstate/`, `ritual.config.yaml`, `decisions/0001-adopt-ritual.md`.

**What's the v0.2 roadmap?**
Tracked as issues at https://github.com/totalnike90/clob-the-builder/issues. Core themes: walk preflight hooks for env-heavy projects, blitz audit stubs, auto-fix budget surfacing, multi-attempt walk reporting, and a one-page ritual overview.

---

## Background reading

The ritual ships with 9 ADRs in `decisions/` explaining the rationale for the major mechanisms:

- [0005](decisions/0005-parallel-tasks-via-worktrees.md) — Parallel tasks via git worktrees and taskstate sidecars
- [0006](decisions/0006-followup-triage-register.md) — Follow-up triage register
- [0007](decisions/0007-human-in-the-loop-walk.md) — Human-in-the-loop `/walk`
- [0021](decisions/0021-reduce-context-bloat-buildlog-followups.md) — Sidecar as source of truth
- [0024](decisions/0024-batch-parallel-ritual.md) — `/batch` parallel orchestrator
- [0031](decisions/0031-automated-ritual-mode.md) — `/auto` retry budgets and auto-fix
- [0032](decisions/0032-blitz-fast-path.md) — `/blitz` session-level bypass
- [0034](decisions/0034-blitz-adhoc-and-scope-brief.md) — Blitz ad-hoc trailers
- [0037](decisions/0037-walk-before-gates-iterative.md) — Reorder walk to immediately after build

---

## Status

**v0.1.0 — initial release.** Full ritual works end-to-end on a clean greenfield project. Five known follow-ups (env-preflight hooks, blitz audit stubs, auto-fix budget surfacing, multi-attempt walk reporting, ritual overview doc) are tracked as v0.2 issues.

## License

[MIT](LICENSE) — see `LICENSE` for the full text.
