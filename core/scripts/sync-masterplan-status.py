#!/usr/bin/env python3
"""Sync task status from .taskstate/<ID>.json sidecars into MASTERPLAN.md tables.

Appends (or refreshes) a `Status` column as the last column of every phase
table whose first header cell is `ID`. Idempotent: re-running updates values
in place rather than adding duplicate columns.

Usage:
    python3 scripts/sync-masterplan-status.py

Run manually when you want MASTERPLAN.md refreshed. Not wired into /ship to
avoid re-introducing the table-padding conflict that the sidecar split was
designed to prevent — two concurrent ships would both touch this file.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTERPLAN = ROOT / "MASTERPLAN.md"
TASKSTATE = ROOT / ".taskstate"

STATUS_LABELS = {
    "shipped": "✓ shipped",
    "reviewed": "◎ reviewed",
    "walked": "◉ walked",
    "checked": "◑ checked",
    "built": "◐ built",
    "in-progress": "◔ in-progress",
    "planned": "◇ planned",
    "todo": "○ todo",
    "blitzed": "▲ blitzed",
    "patched": "◆ patched",
    "blocked": "✗ blocked",
    "reverted": "↺ reverted",
}
CELL_WIDTH = 15

ID_RE = re.compile(r"^\|\s*([A-Z]+-\d+[a-z]?)\s*\|")
HEADER_RE = re.compile(r"^\|\s*ID\s*\|")
SEPARATOR_RE = re.compile(r"^\|\s*[-:]+\s*\|")
STATUS_TAIL_RE = re.compile(r"\|\s*Status\s*\|\s*$")


def load_statuses() -> dict[str, str]:
    out: dict[str, str] = {}
    for path in TASKSTATE.glob("*.json"):
        if path.name.startswith("_"):
            continue
        data = json.loads(path.read_text())
        if "id" not in data or "status" not in data:
            continue
        out[data["id"]] = data["status"]
    return out


def pad_cell(label: str) -> str:
    return label + " " * max(0, CELL_WIDTH - len(label))


def strip_trailing_pipe(line: str) -> str:
    stripped = line.rstrip()
    return stripped[:-1].rstrip() if stripped.endswith("|") else stripped


def append_cell(line: str, cell: str) -> str:
    return f"{strip_trailing_pipe(line)} | {cell} |"


def replace_last_cell(line: str, cell: str) -> str:
    stripped = line.rstrip()
    parts = stripped.split("|")
    # parts looks like ['', ' ID ', ' Task ', ..., ' last-cell ', '']
    parts[-2] = f" {cell} "
    return "|".join(parts)


def sync(text: str, statuses: dict[str, str]) -> tuple[str, int, list[str]]:
    lines = text.splitlines()
    out: list[str] = []
    in_table = False
    header_pipe_count = 0  # pipe count of the table header AFTER any Status column added
    updated = 0
    missing: list[str] = []

    for line in lines:
        if HEADER_RE.match(line):
            in_table = True
            if STATUS_TAIL_RE.search(line):
                out.append(line)
            else:
                out.append(append_cell(line, "Status        "))
            header_pipe_count = out[-1].count("|")
            continue

        if in_table and SEPARATOR_RE.match(line) and out and HEADER_RE.match(out[-1]):
            if line.count("|") < header_pipe_count:
                out.append(append_cell(line, "-" * CELL_WIDTH))
            else:
                out.append(line)
            continue

        match = ID_RE.match(line)
        if in_table and match:
            task_id = match.group(1)
            status = statuses.get(task_id)
            if status is None:
                missing.append(task_id)
                status = "todo"
            label = pad_cell(STATUS_LABELS.get(status, status))
            row_pipes = line.count("|")
            if row_pipes >= header_pipe_count:
                # Row already has a Status column from a prior run — refresh.
                out.append(replace_last_cell(line, label))
            else:
                # Row is one column short — append.
                out.append(append_cell(line, label))
            updated += 1
            continue

        if in_table and not line.lstrip().startswith("|"):
            in_table = False
            header_pipe_count = 0

        out.append(line)

    trailing_nl = "\n" if text.endswith("\n") else ""
    return "\n".join(out) + trailing_nl, updated, missing


def main() -> int:
    if not MASTERPLAN.exists():
        print(f"MASTERPLAN not found at {MASTERPLAN}", file=sys.stderr)
        return 1
    if not TASKSTATE.is_dir():
        print(f".taskstate not found at {TASKSTATE}", file=sys.stderr)
        return 1

    statuses = load_statuses()
    original = MASTERPLAN.read_text()
    new_text, updated, missing = sync(original, statuses)

    if new_text == original:
        print(f"No changes. {updated} rows already in sync.")
        return 0

    MASTERPLAN.write_text(new_text)
    print(f"Synced {updated} task rows into MASTERPLAN.md.")
    if missing:
        print(f"Warning: no sidecar for: {', '.join(sorted(set(missing)))}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
