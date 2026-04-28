---
description: List up to 6 unblocked tasks from MASTERPLAN.md + .taskstate/ and brief one
---

Read-only briefing. No code, no branches, no worktrees, no disk mutations.

## How eligibility works (workflow v2)

- `MASTERPLAN.md` holds plan data (ID, Task, Deps, PRD).
- `.taskstate/<ID>.json` holds state (`status`, `branch`, `worktree`, `pr`, `commit`).
- A task is **eligible** when ALL hold:
  - Sidecar `status: todo`.
  - Every ID in `Deps` has sidecar `status: shipped` **or `status: patched`** (per [ADR 0029](../../decisions/0029-ritual-blast-radius-scaling.md) — `patched` is terminal and deps-satisfying).
  - Every service in `services.json` whose `blocks` array contains this task ID has `status: provisioned`.
  - No local or remote branch matches `task/<id-lowercase>-*`.
  - No worktree exists at `.worktrees/<id-lowercase>`.
- **AG-\* / LI-\*** tasks at `status: planned` (per ADR 0029) are **not** eligible — they are between `/plan-build` and `/build`. Surface in the in-flight list as a gentle reminder ("planned, awaiting /build").

Sidecars drift. Git signals outrank sidecars — treat a task as in flight if **any** of sidecar/branch/worktree says so.

## Steps

1. Read `MASTERPLAN.md` (plan data only).
2. Read every `.taskstate/*.json`. Quick survey: `for f in .taskstate/*.json; do jq -c '{id,status}' "$f"; done`.
3. Build the **in-flight set** from three signals (read-only):

   ```bash
   # sidecar — anything not in a terminal state (todo/shipped/patched/reverted) is in flight
   # patched (ADR 0029) is terminal and deps-satisfying, same as shipped
   INFLIGHT_SIDECAR=$(for f in .taskstate/*.json; do jq -r 'select(.status != "todo" and .status != "shipped" and .status != "patched" and .status != "reverted") | .id' "$f"; done)

   # worktree — extract task IDs from .worktrees/<id>
   INFLIGHT_WORKTREE=$(git worktree list --porcelain | awk '/^worktree .*\/\.worktrees\//{n=split($2,a,"/"); print toupper(a[n])}')

   # branch — any local or remote task/* branch
   INFLIGHT_BRANCH=$(git branch -a --format='%(refname:short)' | grep -oE 'task/[a-z0-9-]+' | sed -E 's|task/([a-z0-9]+)-.*|\1|' | tr a-z A-Z | sort -u)
   ```

   Union → `INFLIGHT_IDS`. Exclude all of them from candidates even if sidecar says `todo`.

4. **Service gate check.** Read `services.json`. For each candidate, check every service whose `blocks` contains the task ID — if `status != "provisioned"`, exclude and record the reason. Surface a **service-gate block above** the eligible list when any task was excluded this way.

   ```
   ⚠ Service gates pending — tasks blocked until services flip to `provisioned`:

     - F-10: waiting on litellm (wave 1), langsmith (wave 1)
     - AG-1: waiting on litellm (wave 1)

   Provision out-of-band, then commit the services.json flip with a `chore:` trailer
   (e.g. `chore: provision litellm`).
   ```

   Quick extraction:

   ```bash
   jq -r '.services | to_entries[] | select(.value.status != "provisioned") | "\(.key)\t\(.value.blocks | join(","))"' services.json
   ```

5. Compute eligibility. Walk in phase order (PR → F → SC → AU → LI → AG → CH → BP), then ID order within each phase. **BP-\* last** — ritual tooling surfaces after product work.

   **PR-\* are human-action** (see MASTERPLAN Phase PR). No branch, no worktree, no `/build`. Suffix them with `(human action — run runbook, commit flip)` in the eligible list. They count toward the "up to 6" cap. A PR-\* service gate is empty — it IS the provisioning that lifts a gate for others.

6. **Drift check.** If any ID appears in `INFLIGHT_WORKTREE`/`INFLIGHT_BRANCH` but its sidecar still says `todo`, surface a drift warning **above** the eligible list:

   ```
   ⚠ Sidecar drift detected — these IDs look in flight but sidecars still say `todo`:

     - F-6 (branch task/f-6-go-gateway-skeleton, worktree .worktrees/f-6)

   Resync before /build: `/build <ID> --adopt` (per ADR 0008 — reclaims branch/worktree
   and flips sidecar to in-progress) or close the stray worktree with
   `git worktree remove .worktrees/<id>` + delete the branch.
   ```

7. **Follow-up drift gate** (per [ADR 0006](../../decisions/0006-followup-triage-register.md), extended by [ADR 0021](../../decisions/0021-reduce-context-bloat-buildlog-followups.md)). Confirm every shipped task's BUILDLOG bullets are registered in its sidecar `follow_ups[]`. Under ADR 0021 the sidecar is source-of-truth; `FOLLOWUPS.md` is generated — do not read it here.

   ```bash
   for f in .taskstate/*.json; do
     [ "$(basename "$f")" = "_notes.json" ] && continue
     status=$(jq -r '.status' "$f")
     [ "$status" != "shipped" ] && continue
     id=$(jq -r '.id' "$f")
     fu_count=$(jq -r '(.follow_ups // []) | length' "$f")
     bl_count=$(python3 scripts/slice-buildlog.py "$id" 2>/dev/null \
       | awk '/^- Follow-ups:/{inf=1;next} /^- / && inf{c++;next} /^## |^<!-- TASK:/{inf=0} END{print c+0}')
     if [ "$fu_count" -lt "$bl_count" ]; then
       echo "DRIFT: $id has $bl_count bullet(s) in BUILDLOG but only $fu_count sidecar entry/entries"
     fi
   done
   ```

   Surface (non-blocking — user can still `/build`):

   ```
   ⚠ Unregistered follow-ups — run /triage before /build:

     - F-6: 2 bullets in BUILDLOG, 0 sidecar entries

   Triage with: /triage F-6   (or /triage --all to backfill everything)
   ```

8. Collect **up to 6** eligible tasks. If none: "All eligible tasks are in progress, reviewed, or shipped. Nothing to plan." Stop.
9. Ask the user which to build next (or let them pick none).
10. For the chosen task: read the PRD `§` (`../specs/SALLY-PRD-Tech-Spec.md`), the prototype in `../prototypes/` if UI-facing, and `../design system/README.md` if visual.

## Output — survey first

```
## Eligible tasks (up to 6)

1. <ID> — <subject> (deps: <list, all shipped ✓>)
2. <ID> — <subject> (deps: <list, all shipped ✓>)
...

You can `/build` any of these in parallel worktrees. Which one should I brief?
```

If the user picks an ID, continue:

```
## Next task: <ID> — <subject>

**PRD references:** <sections + user story IDs>
**Dependencies:** <IDs, all shipped ✓>
**Suggested branch:** task/<id-lowercase>-<kebab-slug>
**Worktree path:** .worktrees/<id-lowercase>

### Acceptance criteria (from PRD)
- <criterion 1, verbatim where possible>
- <criterion 2>

### Files likely to be touched
- <path 1> — <why>

### Approach (short)
<3–6 sentences referencing prototype or design system; flag ambiguity.>

### Questions before /build
<Only if genuinely ambiguous. Otherwise omit.>
```

## Never

- Never let sidecars outrank git signals. Branch or worktree present → task is in flight; surface in Drift check even if sidecar says `todo`.
- Never propose a task with unmet deps, even if it "seems easy in parallel." MASTERPLAN `Deps` + sidecar `status` must both agree.
- Never treat service gates as softer than `Deps`. A task whose deps are all shipped but whose service gate is `pending` is NOT eligible — surface in the service-gate block and skip.
- Never propose scope changes in the briefing. Unclear PRD → flag as a Question; do not invent.
- Never read memory or unrelated files. Stay focused on the survey.
- Suggested branch is pure lowercase kebab-case, prefixed `task/` (e.g. `task/au-4-onboarding-role-picker`).
- Worktree path is always `.worktrees/<id-lowercase>` — no slug, shorter cwd reduces typos.
- Ignore sidecars with `status: blocked` or `reverted` — they need a human decision, not a fresh build.
- For AG-\* / LI-\* tasks a user selects from the eligible list, remind them in the briefing: **`Next step: /plan-build <ID>`** (the plan gate runs before `/build` per [ADR 0029](../../decisions/0029-ritual-blast-radius-scaling.md)). For all other prefixes the briefing's existing "Suggested branch" + "/build <ID>" flow is unchanged.
