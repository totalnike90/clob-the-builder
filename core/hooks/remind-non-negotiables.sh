#!/usr/bin/env bash
# PostToolUse:(Edit|Write|MultiEdit) — when an edit touches a path that the
# project lists as risky in `hooks.remind_paths`, surface the project's
# non-negotiable rules from `.claude/ritual/reviewer.project.md`.
#
# This never blocks. It only injects context. Exits 0 with reminder on
# stderr when relevant, or silently 0 otherwise.
#
# Configure which paths trigger the reminder via `hooks.remind_paths` in
# `ritual.config.yaml` (a YAML list of glob patterns, e.g. ["apps/auth/**",
# "supabase/migrations/**"]). If unset, this hook is a silent no-op.

set -euo pipefail

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
else
  path=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

[ -z "$path" ] && exit 0

# Resolve risky path globs from config. ritual-config.sh returns a space-
# separated list; empty means "no risky paths configured" -> silent no-op.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
remind_paths="$(bash "$SCRIPT_DIR/../scripts/ritual-config.sh" get hooks.remind_paths 2>/dev/null || true)"
[ -z "$remind_paths" ] && exit 0

# Match the path against any configured glob. Bash's `case` handles globs
# natively; we feed each pattern in turn.
matched=""
for pattern in $remind_paths; do
  case "$path" in
    $pattern) matched="yes"; break ;;
  esac
done
[ -z "$matched" ] && exit 0

# Surface the project's non-negotiables from the reviewer rules file.
RULES_FILE="$SCRIPT_DIR/../../reviewer.project.md"
if [ -f "$RULES_FILE" ]; then
  echo "— non-negotiable rules reminder (.claude/ritual/reviewer.project.md) —" >&2
  # Print just the level-3 rule headers so the reminder stays compact.
  grep -E '^### ' "$RULES_FILE" >&2 || true
fi

exit 0
