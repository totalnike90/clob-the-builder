#!/usr/bin/env bash
# BP-17: Propagate local env files (.env.local, .env.*.local) from the main
# checkout into a newly-created worktree so UX-walk screens do not blank on
# missing NEXT_PUBLIC_SUPABASE_URL and similar env. See
# decisions/0033-worktree-env-propagation.md.
#
# Convention: COPY (not symlink). A copy isolates per-worktree overrides such
# as LI-13's LI13_WALK_FIXTURE flag from the main checkout and other sibling
# worktrees. Symlinks would auto-track edits in the main checkout but coupling
# is the wrong default — see ADR 0033 for the trade-off.
#
# Invoked by /build immediately after `git worktree add` +
# `scripts/set-worktree-project-id.sh`. Idempotent — skips files that already
# exist in the destination. Silent no-op if MAIN_ROOT has no matching env
# files (fresh-clone contributors without .env.local yet).
#
# Files propagated: the repo root's .env.local plus any .env.<name>.local.
# Each file is copied to BOTH the worktree root AND apps/web/ — Next 14
# only loads env from the package directory at `next dev` time, not from
# the monorepo root, so a worktree-root copy alone leaves the dev server
# without NEXT_PUBLIC_SUPABASE_URL etc. (BP-23 / ADR 0033). The worktree-
# root copy is still useful for non-Next consumers (Go gateway, Python
# agent, scripts) that look at the repo root.
#
# The apps/web/ mirror is skipped silently when the worktree has no
# apps/web/ dir (keeps the script useful in repos without that layout).
# Per-app env files (apps/*/.env.local) beyond apps/web/ are out of scope
# — adding them is a copy-paste extension if/when a second Next package
# lands.
#
# Usage:
#   scripts/propagate-env-to-worktree.sh [MAIN_ROOT] [WORKTREE_ROOT]
#
# Positional args (both optional — defaults derived from git):
#   MAIN_ROOT      — path to the main checkout (default: $(git worktree list --porcelain | head -1))
#   WORKTREE_ROOT  — path to the destination worktree root (default: pwd)
#
# Env overrides (for tests):
#   MAIN_ROOT      — same as positional
#   WORKTREE_ROOT  — same as positional

set -euo pipefail

log() { printf '[propagate-env] %s\n' "$*"; }

MAIN_ROOT="${1:-${MAIN_ROOT:-}}"
WORKTREE_ROOT="${2:-${WORKTREE_ROOT:-$(pwd)}}"

# Derive MAIN_ROOT from git when unset. The first entry of
# `git worktree list --porcelain` is always the main checkout (the "superproject"
# — git's own term). Works regardless of which worktree we are currently in.
if [ -z "$MAIN_ROOT" ]; then
  if ! command -v git >/dev/null 2>&1; then
    log "git not on PATH and MAIN_ROOT not set — cannot auto-detect main checkout."
    exit 0
  fi
  # awk strips the literal "worktree " prefix instead of using $2 so repo
  # paths containing spaces (e.g. "~/My Projects/sally-mvp") are preserved.
  MAIN_ROOT="$(git -C "$WORKTREE_ROOT" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { sub(/^worktree /, ""); print; exit }' || true)"
  if [ -z "$MAIN_ROOT" ]; then
    log "could not detect main checkout from git — nothing to do."
    exit 0
  fi
fi

# Guard against self-propagation (main == worktree). Happens when someone runs
# the script at the main checkout root; silently no-op since there's nowhere
# to copy to.
if [ "$MAIN_ROOT" = "$WORKTREE_ROOT" ]; then
  log "MAIN_ROOT == WORKTREE_ROOT ($MAIN_ROOT) — nothing to do."
  exit 0
fi

if [ ! -d "$MAIN_ROOT" ]; then
  log "MAIN_ROOT '$MAIN_ROOT' is not a directory — nothing to do."
  exit 0
fi

if [ ! -d "$WORKTREE_ROOT" ]; then
  log "WORKTREE_ROOT '$WORKTREE_ROOT' is not a directory — nothing to do."
  exit 0
fi

# Collect matching env files in MAIN_ROOT. Pattern: .env.local plus any
# .env.<name>.local (Next.js convention). Uses shell globbing with nullglob
# so missing matches expand to an empty list rather than a literal string.
shopt -s nullglob
candidates=()
if [ -f "$MAIN_ROOT/.env.local" ]; then
  candidates+=("$MAIN_ROOT/.env.local")
fi
for f in "$MAIN_ROOT"/.env.*.local; do
  candidates+=("$f")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  log "no .env.local / .env.*.local in $MAIN_ROOT — nothing to propagate."
  exit 0
fi

# Mirror destinations. The worktree root is always a target; apps/web/ is
# added when the directory exists so Next 14's package-local env loader
# finds NEXT_PUBLIC_* vars. New Next packages can be added here.
dests=("$WORKTREE_ROOT")
if [ -d "$WORKTREE_ROOT/apps/web" ]; then
  dests+=("$WORKTREE_ROOT/apps/web")
fi

copied=0
skipped=0
for src in "${candidates[@]}"; do
  base="$(basename "$src")"
  for dest_dir in "${dests[@]}"; do
    dest="$dest_dir/$base"
    if [ -e "$dest" ]; then
      # Idempotent: never clobber a destination file. The worktree may have
      # already been customised with a per-task override (e.g. a walk
      # fixture flag). Re-runs must be safe.
      skipped=$(( skipped + 1 ))
      log "skip $base — already present at $dest_dir/."
      continue
    fi
    # cp -p preserves timestamps + mode (600 on a real .env.local). No -R
    # because env files are plain text, never directories.
    cp -p "$src" "$dest"
    copied=$(( copied + 1 ))
    log "copied $base → $dest_dir/"
  done
done

log "done — $copied copied, $skipped skipped."
