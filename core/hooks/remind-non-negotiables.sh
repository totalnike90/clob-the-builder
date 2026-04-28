#!/usr/bin/env bash
# PostToolUse:(Edit|Write|MultiEdit) — if the edit touched the agent, chat,
# or listing code, remind the model about the §9.3/§9.4 non-negotiable rules.
#
# This never blocks. It only injects context. Exits 0 with reminder on
# stderr when relevant, or silently 0 otherwise.

set -euo pipefail

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
else
  path=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

[ -z "$path" ] && exit 0

# Only remind when we hit risky zones.
case "$path" in
  */apps/agent/*|*/apps/api/*/chat/*|*/apps/web/*/chat/*|*/apps/web/*/listing/*|*/supabase/migrations/*)
    cat >&2 <<'REMINDER'
— non-negotiable rules reminder (CLAUDE.md / PRD §9.3 + §9.4) —
• Buyer identity isolation: never leak one buyer's name/handle across conversations.
• Cross-item isolation: retrieval must filter by listing_id; no shared embeddings across listings.
• Offline block: agent must not transact without seller takeover when mode=buffer and offline.
• show_buy_now: only when seller offline + listing active + price set.
• 7-day return: hardcoded, no seller override.
• RLS on every new table. Service-role key server-side only.
REMINDER
    ;;
esac

exit 0
