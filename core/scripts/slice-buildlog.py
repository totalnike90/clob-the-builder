#!/usr/bin/env python3
"""
Print the BUILDLOG.md block for a single task ID.

    python3 scripts/slice-buildlog.py SC-7

Uses the <!-- TASK:<ID>:START --> ... <!-- TASK:<ID>:END --> anchors added by
backfill-buildlog-anchors.py. Exits 1 (with a hint on stderr) if the task ID
is not found or its block is not properly anchored.

The output is the raw text between the START and END markers (inclusive of
the header line, exclusive of the anchor lines themselves) — suitable for
piping into other tools.

Usage:
    python3 scripts/slice-buildlog.py <ID> [PATH]

PATH defaults to BUILDLOG.md in the repo root.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

START_MARKER = re.compile(r"^<!--\s*TASK:([A-Z]+-\d+[a-z]?):START\s*-->\s*$")
END_MARKER = re.compile(r"^<!--\s*TASK:([A-Z]+-\d+[a-z]?):END\s*-->\s*$")


def slice_block(lines: list[str], task_id: str) -> list[str] | None:
    start: int | None = None
    for i, line in enumerate(lines):
        m = START_MARKER.match(line)
        if m and m.group(1) == task_id:
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        m = END_MARKER.match(lines[j])
        if m and m.group(1) == task_id:
            return lines[start + 1 : j]
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: slice-buildlog.py <ID> [PATH]", file=sys.stderr)
        return 2
    task_id = argv[1]
    path = Path(argv[2]) if len(argv) > 2 else Path("BUILDLOG.md")
    if not path.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 1
    block = slice_block(path.read_text().splitlines(keepends=True), task_id)
    if block is None:
        print(
            f"error: no anchored block for {task_id} in {path}. "
            f"Run scripts/backfill-buildlog-anchors.py to backfill anchors.",
            file=sys.stderr,
        )
        return 1
    sys.stdout.write("".join(block))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
