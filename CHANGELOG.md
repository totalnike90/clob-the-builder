# Changelog

All notable changes to `claude-the-builder` are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Repository scaffolding: `README.md`, `VERSION`, `CHANGELOG.md`, `.gitignore`.

## [0.1.0] — TBD

Initial release. Targets:
- 14 slash commands (`/plan-init`, `/plan-next`, `/plan-build`, `/build`, `/walk`, `/check`, `/review`, `/ship`, `/auto`, `/batch`, `/blitz`, `/patch`, `/triage`, `/doctor`).
- 4 subagents (`reviewer`, `spec-checker`, `visual-diff`, `masterplan-scaffolder`).
- 7 portable scripts and 2 hooks.
- 5 stack presets (pnpm-monorepo, npm-single, python-uv, go-modules, blank).
- `install.sh` + `uninstall.sh` for greenfield and retrofit modes.
- 9 ADRs documenting the ritual mechanism.
