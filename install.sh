#!/usr/bin/env bash
# install.sh — install clob-the-builder ritual into the current project.
#
# Usage:
#   bash /path/to/clob-the-builder/install.sh             # interactive
#   bash /path/to/clob-the-builder/install.sh --apply     # retrofit second pass
#
# Modes (auto-detected):
#   greenfield  — clean repo, no MASTERPLAN.md / .taskstate. Full install.
#   retrofit    — repo has prior conventions. Renders ritual.config.yaml.proposed
#                 and stops. Operator reviews, renames, re-runs with --apply.
#   installed   — already installed (.claude/ritual/.version exists). No-op
#                 with a friendly message.
#
# Requirements:
#   - bash
#   - git
#   - jq (for settings.json deep-merge)
#   - python3 with PyYAML, OR yq (for preset YAML merge)

set -euo pipefail

# ---------- locate clob-the-builder source ----------

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SRC="$(dirname "$script_path")"
[ -d "$SRC/core" ] || { echo "install.sh: cannot locate clob-the-builder core/ alongside the script." >&2; exit 1; }

VERSION="$(cat "$SRC/VERSION")"
PROJECT_DIR="$PWD"

# ---------- argv ----------

APPLY=0
NON_INTERACTIVE=0
PRESET_OVERRIDE=""
PROJECT_NAME_OVERRIDE=""
PRD_PATH_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --preset) PRESET_OVERRIDE="$2"; shift 2 ;;
    --project-name) PROJECT_NAME_OVERRIDE="$2"; shift 2 ;;
    --prd-path) PRD_PATH_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$script_path" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "install.sh: unknown arg '$1'. Run --help." >&2; exit 1 ;;
  esac
done

# ---------- logging helpers ----------

log()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mx\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || err "'$1' not found on PATH. Install it and retry."
}

prompt() {
  local question="$1" default="$2" answer
  if [ "$NON_INTERACTIVE" = 1 ]; then
    printf '%s' "$default"
    return
  fi
  printf '%s ' "$question" >&2
  if [ -n "$default" ]; then printf '[%s] ' "$default" >&2; fi
  read -r answer
  printf '%s' "${answer:-$default}"
}

# ---------- rendering helpers (defined before any use) ----------

# Render a markdown template by substituting tokens. Reads $tmpl, writes $out.
render_md_into() {
  local tmpl="$1" out="$2"
  sed \
    -e "s|{{RITUAL_VERSION}}|$VERSION|g" \
    -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
    -e "s|{{PRD_PATH}}|${PRD_PATH:-<not set — run /plan-init>}|g" \
    -e "s|{{DESIGN_SYSTEM_PATH}}|design/|g" \
    -e "s|{{PROTOTYPES_PATH}}|design/prototypes|g" \
    -e "s|{{INSTALL_DATE}}|$INSTALL_DATE|g" \
    "$tmpl" > "$out"
}

# Render a markdown template to stdout (for inline use in heredocs).
render_md_to_stdout() {
  local tmpl="$1"
  sed \
    -e "s|{{RITUAL_VERSION}}|$VERSION|g" \
    -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
    -e "s|{{PRD_PATH}}|${PRD_PATH:-<not set — run /plan-init>}|g" \
    -e "s|{{DESIGN_SYSTEM_PATH}}|design/|g" \
    -e "s|{{INSTALL_DATE}}|$INSTALL_DATE|g" \
    "$tmpl"
}

# Render the project's ritual.config.yaml from the template + preset.
render_config_into() {
  local out="$1" tmp="$1.tmp"
  sed \
    -e "s|{{RITUAL_VERSION}}|$VERSION|g" \
    -e "s|{{PRD_PATH}}|${PRD_PATH:-}|g" \
    -e "s|{{DESIGN_SYSTEM_PATH}}||g" \
    -e "s|{{PROTOTYPES_PATH}}||g" \
    -e "s|{{GATES_BLOCK}}|  # populated below from preset|g" \
    -e "s|{{DEV_SERVER_CMD}}||g" \
    "$SRC/templates/ritual.config.yaml.tmpl" > "$tmp"

  case "$YAML_BACKEND" in
    yq)
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$tmp" "$PRESET_FILE" > "$out"
      ;;
    python)
      python3 - "$tmp" "$PRESET_FILE" "$out" <<'PY'
import sys, yaml
tmpl, preset_file, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(tmpl) as f:
    cfg = yaml.safe_load(f) or {}
with open(preset_file) as f:
    preset = yaml.safe_load(f) or {}
def deep_merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            deep_merge(a[k], v)
        else:
            a[k] = v
    return a
deep_merge(cfg, preset)
with open(out, 'w') as f:
    yaml.safe_dump(cfg, f, sort_keys=False, default_flow_style=False)
PY
      ;;
  esac
  rm -f "$tmp"
}

# Idempotent file write: render only if destination doesn't already exist.
write_if_absent() {
  local out="$1" tmpl="$2"
  if [ -e "$out" ]; then
    warn "  skip: $out already exists"
    return
  fi
  render_md_into "$tmpl" "$out"
  log "  wrote: $out"
}

# Symlink (preferred) or copy fallback.
link_or_copy() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    warn "  skip: $dst already exists"
    return
  fi
  if ln -s "$src" "$dst" 2>/dev/null; then
    log "  symlinked: $dst → $src"
  else
    cp -R "$src" "$dst"
    log "  copied: $src → $dst (symlinks not supported)"
  fi
}

# ---------- preflight ----------

require git
require jq

if command -v yq >/dev/null 2>&1; then
  YAML_BACKEND="yq"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  YAML_BACKEND="python"
else
  err "neither yq nor python3+PyYAML available. Install one: 'brew install yq' or 'pip install pyyaml'."
fi

git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || err "$PROJECT_DIR is not a git repo. Run 'git init' first."

# ---------- mode detection ----------

ALREADY_INSTALLED=0
HAS_RITUAL_FILES=0
[ -f "$PROJECT_DIR/.claude/ritual/.version" ] && ALREADY_INSTALLED=1

[ -f "$PROJECT_DIR/MASTERPLAN.md" ]    && HAS_RITUAL_FILES=1
[ -d "$PROJECT_DIR/.taskstate" ]       && HAS_RITUAL_FILES=1
[ -d "$PROJECT_DIR/.claude/commands" ] && HAS_RITUAL_FILES=1
[ -f "$PROJECT_DIR/BUILDLOG.md" ]      && HAS_RITUAL_FILES=1

if [ "$ALREADY_INSTALLED" = 1 ]; then
  log "clob-the-builder v$(cat "$PROJECT_DIR/.claude/ritual/.version") is already installed in this project."
  log "To upgrade: re-run after updating your local clone of clob-the-builder."
  log "To uninstall: bash $SRC/uninstall.sh"
  exit 0
fi

if [ "$HAS_RITUAL_FILES" = 1 ] && [ "$APPLY" = 0 ]; then
  MODE="retrofit"
elif [ "$APPLY" = 1 ]; then
  MODE="apply"
else
  MODE="greenfield"
fi

log "Mode: $MODE"

# ---------- preset detection ----------

detect_preset() {
  if [ -f "$PROJECT_DIR/pnpm-workspace.yaml" ] || \
     ([ -f "$PROJECT_DIR/package.json" ] && grep -q '"workspaces"' "$PROJECT_DIR/package.json" 2>/dev/null); then
    echo "pnpm-monorepo"
  elif [ -f "$PROJECT_DIR/package.json" ]; then
    echo "npm-single"
  elif [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/uv.lock" ]; then
    echo "python-uv"
  elif [ -f "$PROJECT_DIR/go.mod" ]; then
    echo "go-modules"
  else
    echo "blank"
  fi
}

DETECTED_PRESET="$(detect_preset)"

# ---------- collect inputs ----------

if [ -n "$PROJECT_NAME_OVERRIDE" ]; then
  PROJECT_NAME="$PROJECT_NAME_OVERRIDE"
else
  PROJECT_NAME="$(prompt 'Project name?' "$(basename "$PROJECT_DIR")")"
fi

if [ -n "$PRESET_OVERRIDE" ]; then
  PRESET="$PRESET_OVERRIDE"
else
  PRESET="$(prompt "Preset? (pnpm-monorepo / npm-single / python-uv / go-modules / blank)" "$DETECTED_PRESET")"
fi
PRESET_FILE="$SRC/presets/${PRESET}.yaml"
[ -f "$PRESET_FILE" ] || err "preset '$PRESET' not found. Available: $(ls "$SRC/presets/" | tr '\n' ' ')"

if [ -n "$PRD_PATH_OVERRIDE" ]; then
  PRD_PATH="$PRD_PATH_OVERRIDE"
else
  PRD_PATH="$(prompt 'PRD path? (leave empty if you will run /plan-init)' '')"
fi

INSTALL_DATE="$(date -u +%Y-%m-%d)"

# ---------- retrofit: render proposed and stop ----------

if [ "$MODE" = "retrofit" ]; then
  log "Existing ritual artifacts detected. Rendering ritual.config.yaml.proposed; will not overwrite."
  if [ -f "$PROJECT_DIR/ritual.config.yaml.proposed" ]; then
    warn "ritual.config.yaml.proposed already exists. Inspect, rename to ritual.config.yaml, then re-run with --apply."
    exit 0
  fi
  render_config_into "$PROJECT_DIR/ritual.config.yaml.proposed"
  log "Wrote ritual.config.yaml.proposed."
  log "Inspect it, rename to ritual.config.yaml, then re-run: bash $script_path --apply"
  exit 0
fi

# ---------- write to project ----------

log "Installing clob-the-builder v$VERSION into $PROJECT_DIR"

# 1. Copy core/ → .claude/ritual/.
mkdir -p "$PROJECT_DIR/.claude"
if [ -d "$PROJECT_DIR/.claude/ritual" ]; then
  warn "  skip: .claude/ritual/ already exists"
else
  cp -R "$SRC/core" "$PROJECT_DIR/.claude/ritual"
  log "  copied: core/ → .claude/ritual/"
fi

# 2. Symlink .claude/{commands,agents,hooks}/ into .claude/ritual/.
link_or_copy "$PROJECT_DIR/.claude/ritual/commands" "$PROJECT_DIR/.claude/commands"
link_or_copy "$PROJECT_DIR/.claude/ritual/agents"   "$PROJECT_DIR/.claude/agents"
link_or_copy "$PROJECT_DIR/.claude/ritual/hooks"    "$PROJECT_DIR/.claude/hooks"

# 3. Render ritual.config.yaml.
if [ -f "$PROJECT_DIR/ritual.config.yaml" ]; then
  warn "  skip: ritual.config.yaml already exists"
else
  render_config_into "$PROJECT_DIR/ritual.config.yaml"
  log "  wrote: ritual.config.yaml (preset=$PRESET)"
fi

# 4. Render markdown templates.
write_if_absent "$PROJECT_DIR/MASTERPLAN.md"            "$SRC/templates/MASTERPLAN.md.tmpl"
write_if_absent "$PROJECT_DIR/BUILDLOG.md"              "$SRC/templates/BUILDLOG.md.tmpl"
write_if_absent "$PROJECT_DIR/FOLLOWUPS.md"             "$SRC/templates/FOLLOWUPS.md.tmpl"
write_if_absent "$PROJECT_DIR/.claude/ritual/reviewer.project.md" "$SRC/templates/reviewer.project.md.tmpl"

mkdir -p "$PROJECT_DIR/decisions"
write_if_absent "$PROJECT_DIR/decisions/0001-adopt-ritual.md" "$SRC/templates/decisions/0001-adopt-ritual.md.tmpl"

# 5. Stub dirs.
mkdir -p "$PROJECT_DIR/.taskstate"
[ -f "$PROJECT_DIR/.taskstate/.gitkeep" ] || touch "$PROJECT_DIR/.taskstate/.gitkeep"
mkdir -p "$PROJECT_DIR/.worktrees"
[ -f "$PROJECT_DIR/.worktrees/.gitkeep" ] || touch "$PROJECT_DIR/.worktrees/.gitkeep"

# 6. Deep-merge .claude/settings.json.
SETTINGS_FILE="$PROJECT_DIR/.claude/settings.json"
ALLOW_TMPL="$SRC/templates/settings.allowlist.json.tmpl"
if [ -f "$SETTINGS_FILE" ]; then
  jq -s '
    .[0] as $existing |
    .[1] as $tmpl |
    $existing
    | .permissions.allow = (((.permissions.allow // []) + ($tmpl.permissions.allow // [])) | unique)
    | .hooks.PreToolUse = (((.hooks.PreToolUse // []) + ($tmpl.hooks.PreToolUse // [])))
    | .hooks.PostToolUse = (((.hooks.PostToolUse // []) + ($tmpl.hooks.PostToolUse // [])))
  ' "$SETTINGS_FILE" "$ALLOW_TMPL" > "$SETTINGS_FILE.tmp" \
    && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  log "  merged: .claude/settings.json"
else
  cp "$ALLOW_TMPL" "$SETTINGS_FILE"
  log "  wrote: .claude/settings.json"
fi

# 7. Append CLAUDE.ritual-section to CLAUDE.md (or create CLAUDE.md).
CLAUDE_FILE="$PROJECT_DIR/CLAUDE.md"
SECTION_TMPL="$SRC/templates/CLAUDE.ritual-section.md.tmpl"
if [ -f "$CLAUDE_FILE" ]; then
  if grep -q '<!-- ritual:start' "$CLAUDE_FILE"; then
    warn "  skip: CLAUDE.md already contains a ritual block"
  else
    {
      cat "$CLAUDE_FILE"
      echo
      render_md_to_stdout "$SECTION_TMPL"
    } > "$CLAUDE_FILE.tmp"
    mv "$CLAUDE_FILE.tmp" "$CLAUDE_FILE"
    log "  appended ritual block to CLAUDE.md"
  fi
else
  {
    echo "# $PROJECT_NAME — CLAUDE.md"
    echo
    echo "Project context for Claude Code."
    echo
    render_md_to_stdout "$SECTION_TMPL"
  } > "$CLAUDE_FILE"
  log "  wrote: CLAUDE.md"
fi

# 8. Stamp version.
echo "$VERSION" > "$PROJECT_DIR/.claude/ritual/.version"

# ---------- next steps ----------

cat <<NEXT

Done. clob-the-builder v$VERSION installed in $PROJECT_DIR.

Next step:
  Open Claude Code in this repo and run:

    /plan-init <PATH-TO-YOUR-PRD>

  This scaffolds MASTERPLAN.md, populates the prefix taxonomy in
  ritual.config.yaml, and writes per-task .taskstate/<ID>.json sidecars.
  After that, /plan-next is usable.

Files added or modified:
  ritual.config.yaml          (preset: $PRESET)
  MASTERPLAN.md               (stub — populate with /plan-init)
  BUILDLOG.md, FOLLOWUPS.md
  CLAUDE.md                   (ritual block appended/created)
  .claude/ritual/             (commands, agents, hooks, scripts)
  .claude/{commands,agents,hooks}/  (symlinks into .claude/ritual/)
  .claude/settings.json       (deep-merged with allowlist)
  .taskstate/, .worktrees/    (stub dirs)
  decisions/0001-adopt-ritual.md

To uninstall:
  bash $SRC/uninstall.sh
NEXT
