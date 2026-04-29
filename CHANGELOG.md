# Changelog

All notable changes to `claude-the-builder` are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).

## [0.1.0] — 2026-04-29

Initial release.

### Added

- 14 slash commands: `/plan-init`, `/plan-next`, `/plan-build`, `/build`, `/walk`, `/check`, `/review`, `/ship`, `/auto`, `/batch`, `/blitz`, `/patch`, `/triage`, `/doctor`.
- 4 subagents: `reviewer`, `spec-checker`, `visual-diff`, `masterplan-scaffolder`.
- 7 portable scripts (`ritual-config.sh`, `slice-buildlog.py`, `regen-followups.py`, `doctor.py`, `propagate-env-to-worktree.sh`, `backfill-buildlog-anchors.py`, `sync-masterplan-status.py`).
- 2 hooks (`guard-main.sh`, `remind-non-negotiables.sh`).
- 5 stack presets: pnpm-monorepo, npm-single, python-uv, go-modules, blank.
- 8 markdown templates for project artifacts.
- `install.sh` (greenfield + retrofit modes) and `uninstall.sh` (idempotent reverse).
- 9 ADRs documenting the ritual mechanism (0005, 0006, 0007, 0021, 0024, 0031, 0032, 0034, 0037).
- Greenfield Next.js example with a seed PRD.
- 9-test bats suite for install/uninstall idempotency.
- MIT License.

### Verified (v0.1.0 release gates)

- Static analysis: zero coupling tokens to any donor project across `core/` + `templates/`.
- Greenfield install creates 14 commands + 4 agents + 7 scripts + 2 hooks.
- `prefixes:` ships empty so the empty-prefix preflight fires until `/plan-init` runs.
- Re-running install detects already-installed and exits cleanly.
- Uninstall removes ritual artifacts and preserves project history; idempotent.
- Preset auto-detection works for pnpm/npm/python-uv/go-modules.
- Bats suite: 9 of 9 tests pass.
- `guard-main` hook blocks commits on `main` with exit 2.
- Reviewer agent reads `reviewer.project.md` for project non-negotiables.

### Known v0.2 follow-ups (tracked as issues)

1. `walk.preflight` config + per-prefix env preflight hooks for environment-heavy projects.
2. `/blitz` walk-skip audit stub for UX-touching code that bypasses `/walk`.
3. `/auto` retry budget exhaustion surfacing in sidecar + BUILDLOG.
4. `/doctor` multi-attempt walk reporting (≥3 attempts in last 30 days).
5. One-page `RITUAL-OVERVIEW.md` mapping ritual ADRs to ritual steps.

### Not verified in v0.1.0 (require live Claude Code)

- `/plan-init` end-to-end scaffold of a greenfield example PRD (the masterplan-scaffolder agent is shipped; live execution is a manual smoke test for downstream users).
- Re-run `/plan-init` blocked by populated prefixes preflight.
- Full ritual loop (`/plan-next` → `/ship`) on a scaffolded project.
