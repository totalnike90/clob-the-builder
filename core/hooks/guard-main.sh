#!/usr/bin/env bash
# PreToolUse:Bash — blocks destructive or ritual-breaking commands.
#
# Reads the tool invocation from stdin as JSON:
#   { "tool_input": { "command": "..." } }
# Exits 0 to allow. Exits 2 with a message on stderr to block and surface
# the message to the model.

set -euo pipefail

# Read tool input JSON from stdin.
input=$(cat)

# Extract the command. Fall back gracefully if jq isn't available.
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
  # Fallback: naive extraction (good enough for our patterns).
  cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

[ -z "$cmd" ] && exit 0

block() {
  echo "BLOCKED by .claude/hooks/guard-main.sh: $1" >&2
  echo "If you really mean to do this, run it outside the Claude session or write an ADR first." >&2
  exit 2
}

# Determine current branch if inside this repo.
branch=$(git -C "$(pwd)" branch --show-current 2>/dev/null || echo "")

# --- Rules ---------------------------------------------------------------

# 1. No direct commits on main. Ritual: /build on a task branch.
#    Narrow exceptions (ADR 0004 + ADR 0010 + ADR 0012 + ADR 0032) — seven permitted shapes on main:
#      - 'chore: ship <ID>'                  ritual /ship metadata commit (ADR 0004)
#      - 'chore: buildlog fix <ID>'          retroactive BUILDLOG correction (ADR 0004)
#      - 'chore: provision <service>'        PR-* sidecar + services.json flip (ADR 0009/0010)
#      - 'chore: add PR-<N>[...]'            plan-scope add of a new PR-* row (ADR 0010)
#      - 'chore: adopt ADR-<N>[...]'         ADR landing with its own meta-edits (ADR 0012)
#      - 'chore: ship blitz <slug>'          /blitz Phase 2 Step 10 admin commit (ADR 0032)
#      - '<ID>: <subject>'                   /blitz Phase 2 Step 9 per-task squash (ADR 0032)
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])git[[:space:]]+commit([[:space:]]|$)'; then
  if [ "$branch" = "main" ]; then
    # BSD/macOS grep has no -P; we rely on grep -E reading the command text
    # line-by-line (HEREDOCs in commit messages arrive with literal newlines),
    # so anchoring to '^' matches the start of any line including the squash
    # message body.
    blitz_squash_re='^[A-Z]+-[0-9]+:[[:space:]]'
    blitz_admin_re='chore:[[:space:]]*ship[[:space:]]+blitz[[:space:]]+[a-z][a-z0-9-]*'
    chore_re='chore:[[:space:]]*(ship[[:space:]]+[A-Z]+-[0-9]+|buildlog[[:space:]]+fix[[:space:]]+[A-Z]+-[0-9]+|provision[[:space:]]+[a-z0-9_-]+|add[[:space:]]+PR-[0-9]+|adopt[[:space:]]+ADR-[0-9]+)'
    if ! printf '%s' "$cmd" | grep -Eq "$chore_re" \
      && ! printf '%s' "$cmd" | grep -Eq "$blitz_admin_re" \
      && ! printf '%s' "$cmd" | grep -Eq "$blitz_squash_re"; then
      block "git commit on 'main' — start a task branch with /build <ID> first. Allowed on main: 'chore: ship <ID>', 'chore: buildlog fix <ID>', 'chore: provision <service>', 'chore: add PR-<N>', 'chore: adopt ADR-<N>', 'chore: ship blitz <slug>', '<ID>: <subject>' (see ADR 0004, ADR 0010, ADR 0012, ADR 0032)."
    fi
  fi
fi

# 2. No --amend (we append new commits, never amend).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+commit[[:space:]].*--amend'; then
  block "git commit --amend is forbidden — always create a new commit (CLAUDE.md)."
fi

# 3. No skipping hooks.
if printf '%s' "$cmd" | grep -Eq -- '--no-verify|--no-gpg-sign|-c[[:space:]]+commit\.gpgsign=false'; then
  block "skipping hooks / signing is forbidden on this repo."
fi

# 4. No git add -A / git add . — always stage specific files.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+add[[:space:]]+(-A\b|--all\b|\.$|\*$)'; then
  block "blanket 'git add' is forbidden — stage specific files to avoid leaking secrets or unrelated work."
fi

# 5. No force-push to main.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[[:space:]].*(--force|-f)[[:space:]]?.*(origin[[:space:]]+)?main'; then
  block "force-push to main is forbidden."
fi

# 6. No destructive resets, anywhere.
#    Per ADR 0031 Finding #1: automated ritual (/auto) under Bash(git *) blanket
#    must not be able to reset --hard on a task branch, which would silently drop
#    auto-fix commits mid-retry. Block unconditionally — operators who really need
#    reset --hard can run it outside the Claude session.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard'; then
  block "git reset --hard is forbidden — destructive and silently drops commits. Branch-scope does not matter; /auto's retry loop must not be able to rewind."
fi

# 7. Supabase reset wipes local DB — warn loudly but allow (it's used in SC-* task checks).
if printf '%s' "$cmd" | grep -Eq 'supabase[[:space:]]+db[[:space:]]+reset'; then
  echo "WARNING: 'supabase db reset' will wipe local DB — OK for /check on SC-* tasks." >&2
fi

exit 0
