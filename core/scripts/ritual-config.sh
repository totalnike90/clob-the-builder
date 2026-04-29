#!/usr/bin/env bash
# ritual-config.sh — read values from ritual.config.yaml at runtime.
#
# Purpose: the only YAML I/O point in clob-the-builder. Slash commands
# shell out here instead of parsing YAML themselves.
#
# Backend: prefers `yq` (any v3 or v4) if installed; falls back to
# `python3` with PyYAML. PyYAML ships with most modern python distributions;
# if missing, the script reports a clear remediation.
#
# Config discovery: walks up from $PWD looking for ritual.config.yaml.
# Override with RITUAL_CONFIG=/abs/path/ritual.config.yaml.
#
# Subcommands (all read-only):
#   get <key.path>                    Dotted-path lookup. Empty on missing.
#   gate.cmd <gate-name>              Shorthand for `get gates.<gate>.cmd`.
#   gate.light_eligible <gate-name>   "true" or "false".
#   prefix.list                       Space-separated prefix IDs. Empty if none.
#   prefix.ux <PREFIX>                "true" or "false".
#   prefix.gates <PREFIX>             Space-separated gate names.
#   prefix.task_specific <PREFIX>     Per-prefix task_specific gate cmd. Empty if none.
#   prefix.pre_build_plan_gate <P>    "true" or "false".
#   prefix.name <PREFIX>              Human-readable prefix name.
#   non_negotiables.list              Space-separated non-negotiable IDs.
#   has-prefixes                      Exit 0 if any prefix configured, else exit 1.
#
# Exit codes:
#   0  success (value emitted to stdout, possibly empty)
#   1  config file not found, parse error, or unknown subcommand
#   2  required argument missing
set -euo pipefail

# ---------- helpers ----------

die() { echo "ritual-config.sh: $*" >&2; exit 1; }
require_arg() {
  if [ -z "${1:-}" ]; then
    echo "ritual-config.sh: missing argument" >&2
    exit 2
  fi
}

find_config() {
  if [ -n "${RITUAL_CONFIG:-}" ]; then
    [ -f "$RITUAL_CONFIG" ] || die "RITUAL_CONFIG=$RITUAL_CONFIG not found"
    echo "$RITUAL_CONFIG"
    return
  fi
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/ritual.config.yaml" ]; then
      echo "$dir/ritual.config.yaml"
      return
    fi
    dir="$(dirname "$dir")"
  done
  die "ritual.config.yaml not found in $PWD or any parent"
}

# ---------- backend selection ----------

if command -v yq >/dev/null 2>&1; then
  BACKEND="yq"
  YQ_VERSION="$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
  YQ_MAJOR="${YQ_VERSION%%.*}"
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import yaml' 2>/dev/null; then
    BACKEND="python"
  else
    die "neither yq nor python3+PyYAML available. Install one: 'brew install yq' or 'pip install pyyaml'."
  fi
else
  die "neither yq nor python3 available."
fi

# Read a dotted key path. Returns empty string when missing.
yaml_get() {
  local key="$1" cfg
  cfg="$(find_config)"
  case "$BACKEND" in
    yq)
      # yq v4+ uses `.foo.bar` syntax with `|` for null filtering.
      # yq v3 (Go) syntax differs; both accept `.foo.bar` for most cases.
      if [ "${YQ_MAJOR:-4}" -ge 4 ]; then
        yq eval ".${key} // \"\"" "$cfg" 2>/dev/null | sed 's/^null$//'
      else
        yq r "$cfg" "$key" 2>/dev/null | sed 's/^null$//'
      fi
      ;;
    python)
      python3 - "$cfg" "$key" <<'PY'
import sys, yaml
cfg_path, key = sys.argv[1], sys.argv[2]
with open(cfg_path) as fh:
    data = yaml.safe_load(fh) or {}
node = data
for part in key.split('.'):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        node = None
        break
if node is None:
    print("")
elif isinstance(node, bool):
    # YAML `true`/`false` → lowercase strings (Python's True/False would print capitalized).
    print("true" if node else "false")
elif isinstance(node, list):
    print(" ".join(str(x) for x in node))
elif isinstance(node, dict):
    # Emit keys for dicts, useful for prefix.list-style queries.
    print(" ".join(node.keys()))
else:
    print(node)
PY
      ;;
  esac
}

# ---------- subcommand dispatch ----------

cmd="${1:-}"
[ -z "$cmd" ] && die "usage: ritual-config.sh <subcommand> [args]"
shift || true

case "$cmd" in
  get)
    require_arg "${1:-}"
    yaml_get "$1"
    ;;

  gate.cmd)
    require_arg "${1:-}"
    yaml_get "gates.$1.cmd"
    ;;

  gate.light_eligible)
    require_arg "${1:-}"
    val="$(yaml_get "gates.$1.light_eligible")"
    [ "$val" = "true" ] && echo "true" || echo "false"
    ;;

  prefix.list)
    yaml_get "prefixes"
    ;;

  prefix.ux)
    require_arg "${1:-}"
    val="$(yaml_get "prefixes.$1.ux")"
    [ "$val" = "true" ] && echo "true" || echo "false"
    ;;

  prefix.gates)
    require_arg "${1:-}"
    yaml_get "prefixes.$1.gates"
    ;;

  prefix.task_specific)
    require_arg "${1:-}"
    yaml_get "gates.task_specific.by_prefix.$1"
    ;;

  prefix.pre_build_plan_gate)
    require_arg "${1:-}"
    val="$(yaml_get "prefixes.$1.pre_build_plan_gate")"
    [ "$val" = "true" ] && echo "true" || echo "false"
    ;;

  prefix.name)
    require_arg "${1:-}"
    yaml_get "prefixes.$1.name"
    ;;

  non_negotiables.list)
    # Returns IDs of all non-negotiables.
    cfg="$(find_config)"
    case "$BACKEND" in
      yq)
        if [ "${YQ_MAJOR:-4}" -ge 4 ]; then
          yq eval '.reviewer.non_negotiables[].id' "$cfg" 2>/dev/null | tr '\n' ' '
        else
          yq r "$cfg" 'reviewer.non_negotiables[*].id' 2>/dev/null | tr '\n' ' '
        fi
        ;;
      python)
        python3 - "$cfg" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh) or {}
nns = (data.get('reviewer') or {}).get('non_negotiables') or []
print(" ".join(n.get('id', '') for n in nns if isinstance(n, dict)))
PY
        ;;
    esac
    ;;

  has-prefixes)
    list="$(yaml_get prefixes)"
    if [ -n "$list" ]; then
      exit 0
    else
      exit 1
    fi
    ;;

  -h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    ;;

  *)
    die "unknown subcommand: $cmd. Run 'ritual-config.sh help' for usage."
    ;;
esac
