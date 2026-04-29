# ADR 0001 — Adopt claude-the-builder ritual

**Date:** 2026-04-28
**Status:** Accepted

## Context

This project adopts the task-execution ritual from [claude-the-builder](https://github.com/jerryneoneo/claude-the-builder) v0.1.0.

Rationale: AI-assisted development without discipline drifts. Untracked work, scope creep, broken reverts, no audit trail. The ritual enforces:

- **One task = one branch = one worktree = one squash commit.** Reverts are always 1:1.
- **Sidecar state.** `.taskstate/<ID>.json` is the source of truth. Status lattice: `todo < planned < in-progress < built < walked < reviewed < shipped`.
- **Walk before gates.** Human verifies UX *before* compute is spent on gates and review.
- **Follow-up triage register.** Every reviewer suggestion gets a disposition: resolved, promoted, folded, or dropped.
- **Trailers required.** Every commit carries `Task: <ID>` so `git log` is queryable forever.

## Decision

Install `claude-the-builder` v0.1.0 via `bash install.sh`. Use the slash commands in `.claude/commands/` for all task work. Track state in `.taskstate/<ID>.json`. Author `MASTERPLAN.md` via `/plan-init <PRD-PATH>` before running `/plan-next`.

## Consequences

- Every code change runs through the ritual.
- `MASTERPLAN.md`, `BUILDLOG.md`, `FOLLOWUPS.md`, `.taskstate/`, `.worktrees/` are now project files.
- The reviewer agent enforces project non-negotiables from `.claude/ritual/reviewer.project.md` (generated from `reviewer.non_negotiables` in `ritual.config.yaml`).
- See ADRs 0005, 0006, 0007, 0021, 0024, 0031, 0032, 0034, 0037 in `.claude/ritual/decisions/` (or [upstream](https://github.com/jerryneoneo/claude-the-builder/tree/main/decisions)) for the rationale behind each ritual mechanism.
- Project-specific decisions get their own ADRs starting at 0002.
