# claude-the-builder

A portable, opinionated **task-execution ritual for Claude Code projects** — slash commands, sidecar state, gated quality checks, and a human-in-the-loop walkthrough — packaged so any new repo can adopt it in two commands.

```
git clone https://github.com/jerryneoneo/claude-the-builder.git ~/code/claude-the-builder
cd <your-project>
bash ~/code/claude-the-builder/install.sh
# then, inside Claude Code:
/plan-init docs/PRD.md
```

That's it. You're now running the ritual.

## What you get

A complete task lifecycle:

```
/plan-init        # one-time: scaffold MASTERPLAN.md from your PRD
   ↓
/plan-next        # pick the next unblocked task
   ↓
/build <ID>       # implement on an isolated worktree
   ↓
/walk <ID>        # human walks through the change (UX tasks only)
   ↓
/check <ID>       # format · lint · typecheck · test · build · task-specific
   ↓
/review <ID>      # independent reviewer subagent against the PRD
   ↓
/ship <ID>        # squash-merge under a lock; one task = one commit
```

Plus orchestrators (`/auto`, `/batch`, `/blitz`), audit (`/doctor`), fast-paths (`/patch`), and a follow-up triage register.

## Why

Most AI-assisted coding workflows fall apart on the same things: untracked work, drift between intent and implementation, scope creep, no audit trail, broken reverts. `claude-the-builder` enforces:

- **One task = one branch = one worktree = one squash commit.** Reverts are always 1:1.
- **Sidecar state.** `.taskstate/<ID>.json` is the source of truth. Status lattice: `todo < planned < in-progress < built < walked < reviewed < shipped`.
- **Walk before gates.** Human verifies UX *before* compute is spent on gates and review.
- **Follow-up triage register.** Every reviewer suggestion gets a disposition: resolved, promoted, folded, dropped.
- **Trailers required.** Every commit carries `Task: <ID>` so `git log` is queryable forever.

## Status

Pre-release. v0.1.0 is in active development. See [CHANGELOG.md](CHANGELOG.md) for progress.

## Origin

Extracted from the [SALLY MVP](https://github.com/jerryneoneo/sally-mvp) (a women-first fashion PWA + AI selling agent) where the ritual matured over ~140 tasks. The universal core is here; SALLY-specific bits (Supabase migration gates, design-system enforcement, PRD §9.x rules) stay in SALLY.

See `decisions/` for the rationale behind each ritual mechanism.

## License

TBD — likely MIT.
