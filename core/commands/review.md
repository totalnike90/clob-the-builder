---
description: Independent review of the task by the reviewer subagent. Usage — /review <TASK-ID>
argument-hint: <TASK-ID>
---

You are requesting an independent review for task **$ARGUMENTS** under workflow v2 ([ADR 0005](../../decisions/0005-parallel-tasks-via-worktrees.md)).

0. **Empty-prefix gate.** If `ritual.config.yaml` has no `prefixes:` configured, stop with: *"Run `/plan-init <PRD-PATH>` first. The ritual needs a master plan before tasks can be picked."* Check via:
   ```bash
   if ! bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "Run /plan-init <PRD-PATH> first."; exit 1
   fi
   ```

## Preflight — must run inside the task's worktree

1. Read `.taskstate/$ARGUMENTS.json` from the main checkout.
2. Confirm `pwd` matches sidecar `worktree` and `git branch --show-current` matches `branch`. Off → stop.
3. Confirm sidecar `status: walked` (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md) — `/walk` runs before `/check` + `/review`). `built` → stop: "Run `/walk <ID>` first." `in-progress` → stop (build not finished).
4. **Gate artefacts must exist and be green.** Read `.taskstate/artifacts/$ARGUMENTS/gate-summary.json`. Missing → stop: "`/check $ARGUMENTS` has not been run (or artefacts were cleaned). Run `/check <ID>` first." Any gate `fail` → stop and list it. `skip` is permitted only with a `reason` field; otherwise treat as fail.

## Gather the review package

For the reviewer:

- Task ID, subject, PRD refs.
- PRD section text — copy the relevant paragraphs verbatim, not just the link.
- Full diff: `git diff main...HEAD`.
- Prototype reference if UI: `rg -l "<relevant component>" {{paths.prototypes}}/`.
- Tests added.
- Migrations added.
- Coverage from `.taskstate/artifacts/<ID>/coverage.json` (emitted by `/check`).
- For UX-prefixed tasks: screenshots at `.taskstate/artifacts/<ID>/screenshots/` — attach so design-token drift (hex, radii, spacing) is caught visually.
- The project's non-negotiable rules file: `.claude/ritual/reviewer.project.md` (loaded by the reviewer subagent itself).

## Spawn the reviewer(s)

Primary: Agent tool with `subagent_type: reviewer`. Model **sonnet** for normal tasks. Use **opus** if this is the last task in its prefix (scan `.taskstate/<same-prefix>-*.json` — no sibling with `todo` or `in-progress` → phase-closing → opus).

**Parallel security pass** — dispatch `subagent_type: security-reviewer` _in the same message_ (parallel tool calls) when the task touches authentication, authorization, payment code, secrets management, RLS / row-level access, or any non-negotiable rule with `security: true` in `ritual.config.yaml`. Any CRITICAL from security-reviewer = Fail.

Reviewer prompt (self-contained — no references to this chat):

```
Review task <ID>: <subject>

You have NOT seen the implementation discussion. Your job is an independent check
against the PRD acceptance criteria and the project's non-negotiable rules in
`.claude/ritual/reviewer.project.md`.

PRD section(s):
<paste the relevant PRD paragraphs verbatim>

Diff:
<paste full git diff main...HEAD>

Tests added:
<list>

Migrations added:
<list>

Check (in order):
1. Acceptance criteria — does the diff meet EVERY criterion in the PRD? Call out
   missing, stubbed, or misimplemented.
2. Non-negotiable rules — load `.claude/ritual/reviewer.project.md`. For each rule
   whose `applies_to` array includes the task's prefix, check the diff and report
   Pass/Fail with file:line evidence. Severity `blocker` → fail review.
   Severity `major` → flag but allow Pass with explanation.
3. Design system — if UI: colors, radii, tokens, icons all sourced from the design
   system (see `{{paths.design_system}}/`)? Compare attached screenshots to the
   prototype (`{{paths.prototypes}}/`) — call out token drift. Voice/copy rules
   are project-defined; the reviewer.project.md file enumerates them.
4. Data safety — RLS or equivalent access control on new tables / collections?
   Service-role / privileged credentials scoped to server-side code only?
5. Reverts — self-contained enough to `git revert <sha>` without taking out
   unrelated work?
6. Tests — happy path + ≥1 failure mode? Assert acceptance criteria? Coverage:
   <paste lines_pct>. Flag below-target coverage for touched packages, noting
   whether the gap is acceptable.
7. Code quality — functions <= 50 LOC, files <= 800 LOC, nesting <= 4. Explicit
   error handling, no silent swallow. No hardcoded secrets. No debug print/log
   statements. Flag with file:line.

Output:
Pass / Fail, followed by a numbered list of specific findings with file:line.
If Pass, note non-blocking suggestions for future tasks.
```

## Act on the result

Pass behavior is uniform across all prefixes (per [ADR 0037](../../decisions/0037-walk-before-gates-iterative.md) — the walk-skip for non-UX prefixes lives in `/walk` itself, upstream of `/review`).

- **Pass (any prefix)** → flip sidecar → `status: reviewed`; refresh `updated_at`; commit as `chore: reviewed <ID>` with the task trailer. Tell user: "Reviewed. Run `/ship <ID>`."
- **Fail** → keep sidecar at `walked`, show findings, recommend blockers. Do not auto-fix. User decides whether to edit code in the worktree (which will require a re-walk per ADR 0037 since the diff changes) or override.

`walk_notes` is already populated by the time `/review` runs — `/walk` writes either real attempt entries (UX prefixes) or a synthetic `n/a — non-user-facing` skip entry (non-UX prefixes) before `/check` + `/review`. `/ship` copies the array verbatim into BUILDLOG's Walk notes section.

## Never

- Never show the reviewer our conversation. Never bias it ("I think this is fine"). It is independent by design.
- Never flip to `reviewed` without a Pass from the reviewer subagent. No overrides without an ADR explaining why.
- Never write `walk_notes` from `/review` — that responsibility lives entirely in `/walk` (per ADR 0037). If `walk_notes` is missing or empty when `/review` runs, stop and tell the operator to run `/walk <ID>` first; the preflight `status: walked` check should already prevent this, but treat it as a backstop.
- If the reviewer keeps failing on the same thing after fixes, consult the PRD — the spec may need an ADR.
