#!/usr/bin/env python3
"""
Wrap every BUILDLOG.md entry in stable HTML comment anchors:

    <!-- TASK:<ID>:START -->
    ## YYYY-MM-DD HH:MM SGT — <ID> <subject>
    ...
    <!-- TASK:<ID>:END -->

Idempotent — re-running is a no-op. Entries already wrapped are detected by
neighbouring `<!-- TASK:<ID>:START/END -->` lines.

Entry boundaries: an entry starts at a line matching
    ^##\s+\d{4}-\d{2}-\d{2}.*—\s+([A-Z]+-\d+[a-z]?)\b
and ends at the line before the next such header, or at the last line of the
file (whichever comes first). Any pre-existing START/END markers flanking the
header or the next header are ignored when computing the body boundary so the
algorithm is stable across re-runs.

Usage:
    python3 scripts/backfill-buildlog-anchors.py [PATH]

PATH defaults to BUILDLOG.md in the repo root. Writes back in place.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ENTRY_HEADER = re.compile(
    r"^##\s+\d{4}-\d{2}-\d{2}[^—]*—\s+([A-Z]+-\d+[a-z]?)\b",
)
START_MARKER = re.compile(r"^<!--\s*TASK:([A-Z]+-\d+[a-z]?):START\s*-->\s*$")
END_MARKER = re.compile(r"^<!--\s*TASK:([A-Z]+-\d+[a-z]?):END\s*-->\s*$")


def backfill(lines: list[str]) -> tuple[list[str], int]:
    """Return (new_lines, entries_newly_anchored). Idempotent."""
    headers: list[tuple[int, str]] = [
        (i, ENTRY_HEADER.match(line).group(1))
        for i, line in enumerate(lines)
        if ENTRY_HEADER.match(line)
    ]
    if not headers:
        return lines, 0

    # For each header, compute the actual body span [body_start, body_end)
    # excluding any neighbouring anchors so the algorithm is re-run stable.
    # body_start is the header's line (header is always part of body).
    # body_end is the first line that is the NEXT header OR its START anchor.
    # Existing START above this header / END below this body are noted and
    # re-emitted deterministically.

    new_lines: list[str] = []
    newly = 0
    # Keep track of any "prefix" content before the first entry, and any
    # "suffix" content after the last entry's logical end.
    first_hdr = headers[0][0]

    # Prefix: everything before any anchors attached to the first header.
    # If line first_hdr-1 is a START anchor for the same ID, prefix stops
    # one line earlier.
    prefix_end = first_hdr
    if first_hdr > 0:
        m = START_MARKER.match(lines[first_hdr - 1])
        if m and m.group(1) == headers[0][1]:
            prefix_end = first_hdr - 1
    new_lines.extend(lines[:prefix_end])

    for idx, (hdr_line, task_id) in enumerate(headers):
        is_last = idx == len(headers) - 1
        next_hdr_line = headers[idx + 1][0] if not is_last else len(lines)

        # body_end: first line that is (a) the next header, or (b) its
        # START anchor, or (c) an END anchor belonging to this task (kept
        # inside the body but treated as the seam), whichever comes first.
        body_end = next_hdr_line
        if not is_last:
            next_id = headers[idx + 1][1]
            # If the immediate predecessor of the next header is its START
            # anchor, pull body_end back one line.
            if body_end - 1 >= hdr_line:
                m = START_MARKER.match(lines[body_end - 1])
                if m and m.group(1) == next_id:
                    body_end -= 1

        # Strip pre-existing START anchor for *this* task at hdr_line-1
        body_start = hdr_line
        if hdr_line > 0:
            m = START_MARKER.match(lines[hdr_line - 1])
            if m and m.group(1) == task_id:
                # Already inside prefix handling for idx==0; for idx>0 the
                # anchor belongs to "gap" which was consumed by previous
                # iteration's post-body emission. Nothing to do here.
                pass

        raw_body = lines[body_start:body_end]
        # Strip any existing END anchors for this task from raw_body — we
        # re-emit a canonical one at the correct position.
        stripped_body: list[str] = [
            line
            for line in raw_body
            if not (END_MARKER.match(line) and END_MARKER.match(line).group(1) == task_id)
        ]

        # Find the last non-blank line of the stripped body; that's where
        # the END anchor goes.
        last_non_blank = len(stripped_body) - 1
        while last_non_blank >= 0 and stripped_body[last_non_blank].strip() == "":
            last_non_blank -= 1
        if last_non_blank < 0:
            raise SystemExit(f"malformed: empty body for {task_id} at line {hdr_line + 1}")

        # Determine whether this entry was already properly anchored BEFORE
        # we mutated anything — used only for the "wrapped new entries" count.
        had_start = hdr_line > 0 and bool(
            START_MARKER.match(lines[hdr_line - 1])
            and START_MARKER.match(lines[hdr_line - 1]).group(1) == task_id
        )
        had_end = any(
            END_MARKER.match(line) and END_MARKER.match(line).group(1) == task_id
            for line in raw_body
        )
        if not (had_start and had_end):
            newly += 1

        # Emit START, body up to last non-blank, END, trailing blanks.
        new_lines.append(f"<!-- TASK:{task_id}:START -->\n")
        new_lines.extend(stripped_body[: last_non_blank + 1])
        new_lines.append(f"<!-- TASK:{task_id}:END -->\n")
        new_lines.extend(stripped_body[last_non_blank + 1 :])

        # Emit "gap" lines between body_end and next_hdr_line (these are
        # the next entry's START anchor OR blank lines that belong between
        # entries). Exclude START anchors — those are re-emitted by the
        # next iteration.
        if not is_last:
            next_id = headers[idx + 1][1]
            for line in lines[body_end:next_hdr_line]:
                if START_MARKER.match(line) and START_MARKER.match(line).group(1) == next_id:
                    continue
                new_lines.append(line)
        else:
            # Suffix after the last entry.
            new_lines.extend(lines[body_end:])

    return new_lines, newly


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path("BUILDLOG.md")
    if not path.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 1
    original = path.read_text().splitlines(keepends=True)
    updated, newly = backfill(original)
    total = sum(1 for line in updated if ENTRY_HEADER.match(line))
    if updated == original:
        print(f"no changes — {total} entries already anchored")
        return 0
    path.write_text("".join(updated))
    print(f"anchored {newly} new / {total} total entries in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
