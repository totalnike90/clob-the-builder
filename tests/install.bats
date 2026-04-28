#!/usr/bin/env bats
# Tests for claude-the-builder install.sh / uninstall.sh.
#
# Requires bats-core: brew install bats-core (macOS) or apt install bats (Linux).
# Run from repo root: bats tests/install.bats

setup() {
  # Resolve the claude-the-builder source dir (this test file's grandparent).
  CTB_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CTB_SRC

  # Fresh tmp project per test.
  TMPDIR="$(mktemp -d)"
  export TMPDIR
  cd "$TMPDIR"
  git init -q
}

teardown() {
  cd /tmp
  rm -rf "$TMPDIR"
}

# ---- install: greenfield ----

@test "install.sh creates expected files in a clean repo" {
  echo '{"name":"test","scripts":{"dev":"next dev"}}' > package.json
  run bash "$CTB_SRC/install.sh" \
    --non-interactive --project-name test --preset npm-single
  [ "$status" -eq 0 ]

  # Core dirs.
  [ -d ".claude/ritual" ]
  [ -L ".claude/commands" ] || [ -d ".claude/commands" ]
  [ -L ".claude/agents" ]   || [ -d ".claude/agents" ]
  [ -L ".claude/hooks" ]    || [ -d ".claude/hooks" ]

  # Stub project files.
  [ -f "MASTERPLAN.md" ]
  [ -f "BUILDLOG.md" ]
  [ -f "FOLLOWUPS.md" ]
  [ -f "ritual.config.yaml" ]
  [ -f "CLAUDE.md" ]
  [ -f "decisions/0001-adopt-ritual.md" ]
  [ -f ".claude/settings.json" ]
  [ -f ".claude/ritual/.version" ]
  [ -f ".claude/ritual/reviewer.project.md" ]

  # Sentinel: 14 commands + 4 agents present in ritual/.
  [ "$(ls .claude/ritual/commands/*.md | wc -l)" -ge 14 ]
  [ "$(ls .claude/ritual/agents/*.md   | wc -l)" -ge 4 ]
}

@test "ritual.config.yaml ships with empty prefixes block" {
  echo '{}' > package.json
  bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset blank >/dev/null

  # has-prefixes exits 1 (correct: prefixes is empty).
  run bash .claude/ritual/scripts/ritual-config.sh has-prefixes
  [ "$status" -eq 1 ]

  # prefix.list returns empty string.
  run bash .claude/ritual/scripts/ritual-config.sh prefix.list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ritual.config.yaml gates come from the chosen preset" {
  echo '{}' > pyproject.toml
  bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset python-uv >/dev/null

  run bash .claude/ritual/scripts/ritual-config.sh gate.cmd format
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruff format"* ]]

  run bash .claude/ritual/scripts/ritual-config.sh gate.cmd test
  [[ "$output" == *"pytest"* ]]
}

# ---- install: idempotency ----

@test "install.sh re-run on already-installed project is a no-op" {
  echo '{}' > package.json
  bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset npm-single >/dev/null

  # Snapshot.
  before=$(find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')

  run bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset npm-single
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]

  # Files unchanged.
  after=$(find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')
  [ "$before" = "$after" ]
}

# ---- uninstall ----

@test "uninstall.sh removes ritual artifacts but preserves project history" {
  echo '{}' > package.json
  bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset npm-single >/dev/null

  run bash "$CTB_SRC/uninstall.sh"
  [ "$status" -eq 0 ]

  # Removed.
  [ ! -d ".claude/ritual" ]
  [ ! -L ".claude/commands" ]
  [ ! -L ".claude/agents" ]
  [ ! -L ".claude/hooks" ]

  # Preserved (project history).
  [ -f "MASTERPLAN.md" ]
  [ -f "BUILDLOG.md" ]
  [ -f "FOLLOWUPS.md" ]
  [ -f "ritual.config.yaml" ]
  [ -f "decisions/0001-adopt-ritual.md" ]

  # CLAUDE.md ritual block stripped, file itself preserved.
  [ -f "CLAUDE.md" ]
  ! grep -q "ritual:start" CLAUDE.md
}

@test "uninstall.sh is idempotent" {
  echo '{}' > package.json
  bash "$CTB_SRC/install.sh" --non-interactive --project-name t --preset npm-single >/dev/null
  bash "$CTB_SRC/uninstall.sh" >/dev/null

  # Second uninstall is a no-op (no errors).
  run bash "$CTB_SRC/uninstall.sh"
  [ "$status" -eq 0 ]
}

# ---- preset detection ----

@test "preset auto-detects pnpm-monorepo from pnpm-workspace.yaml" {
  echo "packages:\n  - 'apps/*'" > pnpm-workspace.yaml
  echo '{"name":"t"}' > package.json
  run bash "$CTB_SRC/install.sh" --non-interactive --project-name t
  [ "$status" -eq 0 ]
  grep -q "pnpm" ritual.config.yaml
}

@test "preset auto-detects python-uv from pyproject.toml" {
  echo '[project]\nname = "t"' > pyproject.toml
  run bash "$CTB_SRC/install.sh" --non-interactive --project-name t
  [ "$status" -eq 0 ]
  grep -q "uv " ritual.config.yaml
}

@test "preset auto-detects go-modules from go.mod" {
  echo "module example.com/t" > go.mod
  run bash "$CTB_SRC/install.sh" --non-interactive --project-name t
  [ "$status" -eq 0 ]
  grep -q "go " ritual.config.yaml
}
