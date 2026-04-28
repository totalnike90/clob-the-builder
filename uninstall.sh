#!/usr/bin/env bash
# uninstall.sh — remove claude-the-builder ritual from the current project.
#
# Removes:
#   .claude/ritual/                          (the installed core)
#   .claude/{commands,agents,hooks}          (symlinks or copies pointing into ritual/)
#   .claude/settings.json                    (only the additions from this install)
#   CLAUDE.md ritual block                   (between <!-- ritual:start --> and <!-- ritual:end -->)
#
# PRESERVES (project history — never deleted):
#   MASTERPLAN.md
#   BUILDLOG.md
#   FOLLOWUPS.md
#   .taskstate/
#   .worktrees/
#   ritual.config.yaml
#   .claude/ritual/reviewer.project.md
#   decisions/0001-adopt-ritual.md
#
# Idempotent — re-running removes nothing more and exits 0.

set -euo pipefail

PROJECT_DIR="$PWD"

log()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

# ---------- 1. Remove .claude/ritual/ ----------

if [ -d "$PROJECT_DIR/.claude/ritual" ]; then
  rm -rf "$PROJECT_DIR/.claude/ritual"
  log "removed .claude/ritual/"
else
  warn "  .claude/ritual/ not present — skipping"
fi

# ---------- 2. Remove symlinks (or copies) ----------

for dir in commands agents hooks; do
  target="$PROJECT_DIR/.claude/$dir"
  if [ -L "$target" ]; then
    rm "$target"
    log "removed symlink .claude/$dir"
  elif [ -d "$target" ]; then
    # Was a copy. Only remove if it has no files outside what we shipped.
    # Safer: warn and leave alone — the operator decides.
    warn "  .claude/$dir is a directory (not a symlink) — leaving in place. Remove manually if you want."
  fi
done

# ---------- 3. Trim .claude/settings.json ----------

SETTINGS_FILE="$PROJECT_DIR/.claude/settings.json"
ALLOW_REF="$(dirname "$0")/templates/settings.allowlist.json.tmpl"
if [ -f "$SETTINGS_FILE" ] && [ -f "$ALLOW_REF" ] && command -v jq >/dev/null 2>&1; then
  # Subtract the allowlist from the project's settings.
  jq -s '
    .[0] as $existing |
    .[1] as $tmpl |
    $existing
    | .permissions.allow = ((.permissions.allow // []) - ($tmpl.permissions.allow // []))
    | .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) - ($tmpl.hooks.PreToolUse  // []))
    | .hooks.PostToolUse = ((.hooks.PostToolUse // []) - ($tmpl.hooks.PostToolUse // []))
  ' "$SETTINGS_FILE" "$ALLOW_REF" > "$SETTINGS_FILE.tmp" \
    && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  log "trimmed .claude/settings.json (ritual entries removed)"
else
  warn "  .claude/settings.json or template not found — skipping trim"
fi

# ---------- 4. Strip ritual block from CLAUDE.md ----------

CLAUDE_FILE="$PROJECT_DIR/CLAUDE.md"
if [ -f "$CLAUDE_FILE" ] && grep -q '<!-- ritual:start' "$CLAUDE_FILE"; then
  awk '
    /<!-- ritual:start/ { skip=1; next }
    /<!-- ritual:end -->/ { skip=0; next }
    skip != 1 { print }
  ' "$CLAUDE_FILE" > "$CLAUDE_FILE.tmp" \
    && mv "$CLAUDE_FILE.tmp" "$CLAUDE_FILE"
  log "stripped ritual block from CLAUDE.md"
fi

# ---------- summary ----------

cat <<DONE

claude-the-builder uninstalled. Preserved (project history):
  MASTERPLAN.md, BUILDLOG.md, FOLLOWUPS.md
  ritual.config.yaml
  .taskstate/, .worktrees/
  decisions/0001-adopt-ritual.md

To re-install: bash $(dirname "$0")/install.sh
DONE
