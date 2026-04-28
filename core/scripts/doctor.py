#!/usr/bin/env python3
"""State-drift auditor for the claude-the-builder ritual.

Reads MASTERPLAN.md, `.taskstate/*.json` sidecars (both `main` and any active
worktree branches), `git worktree list`, branch refs, `git log`, and
`git status --porcelain`, then cross-checks them for drift.

Output is a punch list grouped by severity. Read-only by default. Pass `--json`
for machine-readable output. Repair flow is interactive in the slash command
wrapper (`.claude/commands/doctor.md`); this script only diagnoses.

Usage:
    python3 scripts/doctor.py            # human-readable audit
    python3 scripts/doctor.py --json     # machine-readable findings
    python3 scripts/doctor.py --quiet    # exit code only

Exit codes:
    0 — no findings
    1 — findings present (severity BLOCK or WARN)
    2 — findings present but only INFO
    3 — script error (e.g. MASTERPLAN missing)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTERPLAN = ROOT / "MASTERPLAN.md"
TASKSTATE = ROOT / ".taskstate"
WORKTREES_DIR = ROOT / ".worktrees"

NON_TERMINAL = {"todo", "planned", "in-progress", "built", "walked", "checked", "reviewed"}
TERMINAL = {"shipped", "patched", "blitzed", "reverted", "blocked"}

# Status lattice for regression detection. Higher = more advanced.
# Per ADR 0037: walked precedes reviewed (walk runs after build, before
# /check + /review). The legacy `checked` status was never written to
# sidecars (`/check` does not flip status — see check.md "Never") but is
# kept in the lattice for back-compat with any drifted sidecar; map it
# alongside `walked` so its presence does not register as a regression.
LATTICE = {
    "todo": 0,
    "planned": 1,
    "in-progress": 2,
    "built": 3,
    "walked": 4,
    "checked": 4,
    "reviewed": 5,
    "shipped": 6,
    "patched": 6,
    "blitzed": 6,
    "reverted": -1,
    "blocked": -1,
}

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

ID_RE = re.compile(r"^\|\s*([A-Z]+-\d+[a-z]?)\s*\|")
ROW_LAST_CELL_RE = re.compile(r"\|\s*([^|]+?)\s*\|\s*$")

PRODUCT_PATH_PREFIXES = (
    "apps/",
    "packages/",
    "supabase/",
    "scripts/",
)


@dataclass
class Finding:
    severity: str  # BLOCK | WARN | INFO
    code: str
    task_id: str | None
    message: str
    recovery: str

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class TaskView:
    task_id: str
    masterplan_status_text: str | None = None
    main_sidecar_status: str | None = None
    main_sidecar_tracked: bool | None = None
    worktree_sidecar_status: str | None = None
    worktree_path: str | None = None
    branch: str | None = None
    has_main_commit: bool = False
    main_commit_sha: str | None = None


def run(cmd: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def parse_masterplan_rows() -> dict[str, str]:
    """Map task_id → trailing status cell text from MASTERPLAN.md tables."""
    if not MASTERPLAN.is_file():
        return {}
    out: dict[str, str] = {}
    for line in MASTERPLAN.read_text().splitlines():
        m = ID_RE.match(line)
        if not m:
            continue
        task_id = m.group(1)
        last = ROW_LAST_CELL_RE.search(line)
        if last:
            out[task_id] = last.group(1).strip()
    return out


def load_main_sidecars() -> dict[str, dict]:
    """All sidecars currently visible in the main checkout's working tree."""
    out: dict[str, dict] = {}
    if not TASKSTATE.is_dir():
        return out
    for path in TASKSTATE.glob("*.json"):
        if path.name.startswith("_"):
            continue
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if "id" in data and "status" in data:
            out[data["id"]] = data
    return out


def tracked_paths() -> set[str]:
    """Set of paths tracked in HEAD (used to detect untracked sidecars)."""
    code, stdout, _ = run(["git", "ls-files"], cwd=ROOT)
    if code != 0:
        return set()
    return set(stdout.splitlines())


def list_worktrees() -> list[dict[str, str]]:
    """Parse `git worktree list --porcelain`."""
    code, stdout, _ = run(["git", "worktree", "list", "--porcelain"], cwd=ROOT)
    if code != 0:
        return []
    out: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in stdout.splitlines():
        if line.startswith("worktree "):
            if current:
                out.append(current)
            current = {"path": line.split(" ", 1)[1]}
        elif line.startswith("HEAD "):
            current["head"] = line.split(" ", 1)[1]
        elif line.startswith("branch "):
            current["branch"] = line.split(" ", 1)[1].replace("refs/heads/", "")
        elif line == "":
            if current:
                out.append(current)
                current = {}
    if current:
        out.append(current)
    return out


def read_worktree_sidecar(worktree_path: str, task_id: str) -> dict | None:
    sidecar = Path(worktree_path) / ".taskstate" / f"{task_id}.json"
    if not sidecar.is_file():
        return None
    try:
        return json.loads(sidecar.read_text())
    except json.JSONDecodeError:
        return None


def all_branches() -> list[str]:
    code, stdout, _ = run(
        ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads/", "refs/remotes/"],
        cwd=ROOT,
    )
    if code != 0:
        return []
    return [b for b in stdout.splitlines() if b]


def _resolve_main_ref() -> str | None:
    for ref in ("origin/main", "main"):
        code, _, _ = run(["git", "rev-parse", "--verify", ref], cwd=ROOT)
        if code == 0:
            return ref
    return None


# Subjects that are intermediate sidecar updates, not real ships. These can
# carry a `Task: <ID>` trailer but the work hasn't landed on main yet.
INTERMEDIATE_SUBJECT_RE = re.compile(
    r"^chore:\s*(start|adopt|built|reviewed|walked|polish|log|mark)\b",
    re.IGNORECASE,
)


def find_main_commit_for_id(task_id: str) -> str | None:
    """SHA of the real ship/blitz/scaffold commit on main for this task.

    Strategy:
      1. Look for any main commit whose body contains `Task: <ID>` trailer.
      2. Filter out subjects that are intermediate sidecar updates
         (`chore: start|adopt|built|reviewed|walked|polish|log|mark`).
      3. Fallback for legacy commits without trailers: subject `<ID>:` prefix
         or `chore: ship <ID>`.
    """
    main_ref = _resolve_main_ref()
    if not main_ref:
        return None

    # Primary: any main commit with `Task: <ID>` trailer.
    code, stdout, _ = run(
        [
            "git", "log", main_ref,
            "--grep", f"^Task: {re.escape(task_id)}([^A-Za-z0-9-]|$)",
            "-E", "--format=%H%x00%s%x00%x00",
        ],
        cwd=ROOT,
    )
    if code == 0 and stdout.strip():
        for entry in stdout.split("\x00\x00"):
            if not entry.strip():
                continue
            sha, _, subject = entry.partition("\x00")
            if INTERMEDIATE_SUBJECT_RE.match(subject.strip()):
                continue
            return sha.strip()

    # Legacy fallback 1: subject `<ID>:` (PR-merged squash before trailer norm)
    code, stdout, _ = run(
        [
            "git", "log", main_ref,
            "--grep", f"^{re.escape(task_id)}: ",
            "-E", "-n", "1", "--format=%H",
        ],
        cwd=ROOT,
    )
    if code == 0 and stdout.strip():
        return stdout.strip()

    # Legacy fallback 2: subject `chore: ship <ID>` followed by space/EOL.
    code, stdout, _ = run(
        [
            "git", "log", main_ref,
            "--grep", f"^chore: ship {re.escape(task_id)}([^A-Za-z0-9-]|$)",
            "-E", "-n", "1", "--format=%H",
        ],
        cwd=ROOT,
    )
    if code == 0 and stdout.strip():
        return stdout.strip()

    return None


def porcelain_status() -> list[tuple[str, str]]:
    """Returns list of (xy, path) from `git status --porcelain`."""
    code, stdout, _ = run(["git", "status", "--porcelain"], cwd=ROOT)
    if code != 0:
        return []
    out: list[tuple[str, str]] = []
    for line in stdout.splitlines():
        if len(line) < 3:
            continue
        out.append((line[:2], line[3:]))
    return out


def collect_views() -> dict[str, TaskView]:
    masterplan_rows = parse_masterplan_rows()
    main_sidecars = load_main_sidecars()
    tracked = tracked_paths()
    worktrees = list_worktrees()

    # Map task_id → worktree info (lowercase id-based directory match).
    worktree_by_id: dict[str, dict[str, str]] = {}
    for wt in worktrees:
        path = wt.get("path", "")
        if not path:
            continue
        # Convention: worktrees live under .worktrees/<id-lower>/
        try:
            rel = Path(path).resolve().relative_to(ROOT.resolve())
        except ValueError:
            continue
        parts = rel.parts
        if len(parts) >= 2 and parts[0] == ".worktrees":
            worktree_by_id[parts[1]] = wt

    all_ids: set[str] = set(masterplan_rows.keys()) | set(main_sidecars.keys())
    for id_lc in worktree_by_id.keys():
        # Reconstruct uppercase ID by checking sidecars or just upper().
        candidate = id_lc.upper()
        all_ids.add(candidate)

    views: dict[str, TaskView] = {}
    for task_id in sorted(all_ids):
        v = TaskView(task_id=task_id)
        v.masterplan_status_text = masterplan_rows.get(task_id)
        if task_id in main_sidecars:
            v.main_sidecar_status = main_sidecars[task_id].get("status")
            v.main_sidecar_tracked = (
                f".taskstate/{task_id}.json" in tracked
            )
        wt = worktree_by_id.get(task_id.lower())
        if wt:
            v.worktree_path = wt.get("path")
            v.branch = wt.get("branch")
            sc = read_worktree_sidecar(wt["path"], task_id) if wt.get("path") else None
            if sc:
                v.worktree_sidecar_status = sc.get("status")
        sha = find_main_commit_for_id(task_id)
        if sha:
            v.has_main_commit = True
            v.main_commit_sha = sha
        views[task_id] = v
    return views


# --- Drift rules ---------------------------------------------------------

def status_label(status: str | None) -> str:
    if not status:
        return ""
    return STATUS_LABELS.get(status, status)


def check_masterplan_symbol_drift(view: TaskView) -> Finding | None:
    """MASTERPLAN row trailing cell must match sidecar status label.

    The sidecar of record is the worktree's sidecar if a worktree is active;
    otherwise the main sidecar.
    """
    if view.masterplan_status_text is None:
        return None
    canonical_status = view.worktree_sidecar_status or view.main_sidecar_status
    if not canonical_status:
        return None
    expected = status_label(canonical_status)
    actual = view.masterplan_status_text
    if expected.strip() == actual.strip():
        return None
    # Tolerate the "raw status word" form the legacy sync script produces
    # for labels it doesn't know (e.g. `blitzed`).
    if actual.strip() == canonical_status:
        return None
    source = "worktree" if view.worktree_sidecar_status else "main sidecar"
    return Finding(
        severity="WARN",
        code="masterplan-symbol-drift",
        task_id=view.task_id,
        message=(
            f"MASTERPLAN row says '{actual}' but {source} says "
            f"'{canonical_status}'."
        ),
        recovery=(
            f"Run `python3 scripts/sync-masterplan-status.py` after the next "
            f"`/ship` or `/blitz` lands. For in-flight tasks the row only "
            f"refreshes at the next serialized merge — use `/doctor` to view "
            f"live worktree status."
        ),
    )


def check_untracked_sidecar(view: TaskView) -> Finding | None:
    if view.main_sidecar_status is None:
        return None
    if view.main_sidecar_tracked is False:
        return Finding(
            severity="BLOCK",
            code="untracked-sidecar",
            task_id=view.task_id,
            message=(
                f".taskstate/{view.task_id}.json exists but is untracked in git."
            ),
            recovery=(
                f"Decide: (a) commit it as `chore: scaffold {view.task_id}` "
                f"alongside the MASTERPLAN row addition, or (b) `rm "
                f".taskstate/{view.task_id}.json` and revert the MASTERPLAN row."
            ),
        )
    return None


def check_inflight_needs_branch_and_worktree(view: TaskView) -> Finding | None:
    canonical_status = view.worktree_sidecar_status or view.main_sidecar_status
    if canonical_status not in NON_TERMINAL or canonical_status in {"todo", "planned"}:
        return None
    if not view.worktree_path:
        return Finding(
            severity="BLOCK",
            code="inflight-without-worktree",
            task_id=view.task_id,
            message=(
                f"Sidecar status is '{canonical_status}' but no worktree is registered."
            ),
            recovery=(
                f"Either run `/build --adopt {view.task_id}` to recreate the "
                f"worktree, or roll the sidecar back to `todo`."
            ),
        )
    return None


def check_orphaned_worktree(view: TaskView) -> Finding | None:
    if not view.worktree_path:
        return None
    canonical_status = view.worktree_sidecar_status or view.main_sidecar_status
    if canonical_status in TERMINAL:
        return Finding(
            severity="WARN",
            code="orphaned-worktree",
            task_id=view.task_id,
            message=(
                f"Worktree at {view.worktree_path} still exists but sidecar "
                f"is terminal ('{canonical_status}')."
            ),
            recovery=(
                f"`git worktree remove {view.worktree_path}` from the main "
                f"checkout (only after confirming nothing in-flight is held there)."
            ),
        )
    return None


def check_split_brain_worktree_main(view: TaskView) -> Finding | None:
    """Worktree sidecar advanced beyond the main sidecar — common drift."""
    if not view.worktree_sidecar_status or not view.main_sidecar_status:
        return None
    wt_rank = LATTICE.get(view.worktree_sidecar_status, 0)
    main_rank = LATTICE.get(view.main_sidecar_status, 0)
    # Main is expected to lag worktree by design; only flag if the worktree
    # is at a non-terminal advanced state AND the task has no main commit
    # AND the worktree status is `walked`/`reviewed` (i.e. mid-ritual past
    # build, per ADR 0037 lattice).
    if (
        wt_rank > main_rank
        and view.worktree_sidecar_status in {"walked", "reviewed"}
        and not view.has_main_commit
    ):
        if view.worktree_sidecar_status == "reviewed":
            next_step = "`/ship`"
        else:  # walked
            next_step = "`/check` then `/review` then `/ship`"
        return Finding(
            severity="WARN",
            code="stranded-inflight",
            task_id=view.task_id,
            message=(
                f"Worktree sidecar at '{view.worktree_sidecar_status}' but main "
                f"sidecar still '{view.main_sidecar_status}' — task mid-ritual "
                f"but hasn't landed."
            ),
            recovery=f"Next ritual step: {next_step} inside {view.worktree_path}.",
        )
    return None


def check_terminal_without_main_commit(view: TaskView) -> Finding | None:
    canonical_status = view.main_sidecar_status
    if canonical_status not in {"shipped", "patched", "blitzed"}:
        return None
    if not view.has_main_commit:
        return Finding(
            severity="BLOCK",
            code="terminal-without-commit",
            task_id=view.task_id,
            message=(
                f"Sidecar says '{canonical_status}' but no commit on main "
                f"mentions Task: {view.task_id}."
            ),
            recovery=(
                f"Check git reflog and dangling commits — work may have been "
                f"lost. Otherwise, sidecar was advanced incorrectly; roll back."
            ),
        )
    return None


def check_global_uncommitted_state() -> list[Finding]:
    """Global findings about uncommitted state on main."""
    findings: list[Finding] = []
    code, branch_out, _ = run(["git", "branch", "--show-current"], cwd=ROOT)
    on_main = code == 0 and branch_out.strip() == "main"
    if not on_main:
        return findings

    for xy, path in porcelain_status():
        # Untracked sidecars are caught per-task elsewhere — skip here to avoid duplication.
        if path.startswith(".taskstate/") and path.endswith(".json"):
            if xy == "??":
                continue  # already reported per-task
        # Untracked decision files — flag.
        if xy == "??" and path.startswith("decisions/") and path.endswith(".md"):
            findings.append(
                Finding(
                    severity="WARN",
                    code="untracked-decision",
                    task_id=None,
                    message=f"Untracked ADR draft: {path}",
                    recovery=(
                        f"Either commit as `chore: adopt ADR-XXXX` on main, "
                        f"or `rm {path}` if abandoned."
                    ),
                )
            )
            continue
        # Modified product code on main — flag.
        is_product = any(path.startswith(p) for p in PRODUCT_PATH_PREFIXES)
        if is_product and xy.strip() in {"M", "MM", "AM", "??"}:
            findings.append(
                Finding(
                    severity="BLOCK",
                    code="dirty-product-code-on-main",
                    task_id=None,
                    message=f"Product code modified on main without a Task: {path}",
                    recovery=(
                        f"Move the change into the relevant task's worktree "
                        f"and commit there with a Task: trailer, or revert "
                        f"with `git checkout -- {path}` on main."
                    ),
                )
            )
    return findings


# --- Aggregation ---------------------------------------------------------

PER_TASK_RULES = (
    check_untracked_sidecar,
    check_terminal_without_main_commit,
    check_inflight_needs_branch_and_worktree,
    check_orphaned_worktree,
    check_split_brain_worktree_main,
    check_masterplan_symbol_drift,
)


def audit() -> list[Finding]:
    findings: list[Finding] = []
    views = collect_views()
    for view in views.values():
        for rule in PER_TASK_RULES:
            f = rule(view)
            if f:
                findings.append(f)
    findings.extend(check_global_uncommitted_state())
    return findings


# --- Output --------------------------------------------------------------

SEVERITY_ORDER = {"BLOCK": 0, "WARN": 1, "INFO": 2}


def print_human(findings: list[Finding]) -> None:
    if not findings:
        print("Doctor: no drift findings. ✓")
        return
    findings_sorted = sorted(
        findings,
        key=lambda f: (SEVERITY_ORDER.get(f.severity, 3), f.task_id or "", f.code),
    )
    bucket: dict[str, list[Finding]] = {"BLOCK": [], "WARN": [], "INFO": []}
    for f in findings_sorted:
        bucket.setdefault(f.severity, []).append(f)
    print(
        f"Doctor: {len(findings)} finding(s) — "
        f"{len(bucket['BLOCK'])} BLOCK, "
        f"{len(bucket['WARN'])} WARN, "
        f"{len(bucket['INFO'])} INFO."
    )
    print()
    for severity in ("BLOCK", "WARN", "INFO"):
        items = bucket.get(severity) or []
        if not items:
            continue
        print(f"## {severity}")
        print()
        for f in items:
            scope = f.task_id or "global"
            print(f"- [{f.code}] ({scope}) {f.message}")
            print(f"  Recovery: {f.recovery}")
        print()


def print_json(findings: list[Finding]) -> None:
    payload = {
        "count": len(findings),
        "findings": [f.to_dict() for f in findings],
    }
    print(json.dumps(payload, indent=2))


def exit_code(findings: list[Finding]) -> int:
    if not findings:
        return 0
    if any(f.severity in {"BLOCK", "WARN"} for f in findings):
        return 1
    return 2


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--quiet", action="store_true", help="exit code only, no output")
    args = parser.parse_args(argv)

    if not MASTERPLAN.is_file():
        print(f"error: {MASTERPLAN} not found", file=sys.stderr)
        return 3

    findings = audit()
    if args.quiet:
        return exit_code(findings)
    if args.json:
        print_json(findings)
    else:
        print_human(findings)
    return exit_code(findings)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
