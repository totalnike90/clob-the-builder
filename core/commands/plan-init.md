---
description: Genesis command — scaffold MASTERPLAN.md from your PRD before /plan-next is usable. Usage — /plan-init <PRD-PATH> [--screens <DIR>] [--prefix-hint A,B,C] [--dry-run]
argument-hint: <PRD-PATH> [--screens <DIR>] [--prefix-hint A,B,C] [--dry-run]
---

You are scaffolding the master plan for this project from its PRD. Run once after `bash install.sh`, before `/plan-next` is usable.

Parse `$ARGUMENTS`:
- First positional: `<PRD-PATH>` (required) — path to PRD (`.md`, `.txt`, or `.pdf`).
- `--screens <DIR>` (optional) — directory of UI mockups (PNG/JPG/JSX). Biases prefix proposals toward UX-heavy taxonomy.
- `--prefix-hint A,B,C` (optional) — operator override; force these prefix letters into the proposal.
- `--dry-run` (optional) — render `.draft` files and stop without committing.

## Preflight

1. Verify install.sh has run: `[ -f .claude/ritual/.version ]` and `[ -f ritual.config.yaml ]`. Else stop: `"Run bash install.sh first."`

2. Verify `prefixes:` is empty in `ritual.config.yaml`:
   ```bash
   if bash .claude/ritual/scripts/ritual-config.sh has-prefixes; then
     echo "MASTERPLAN already scaffolded. To re-scaffold, edit MASTERPLAN.md by hand."
     exit 1
   fi
   ```
   If non-empty, stop with the message above. (`--re-scaffold` is a future v0.2 feature.)

3. Verify the PRD path:
   ```bash
   PRD_PATH="<first positional arg>"
   [ -f "$PRD_PATH" ] || { echo "PRD not found at $PRD_PATH"; exit 1; }
   ```
   If `.pdf`, require `pdftotext` on PATH; else stop with: `"Install pdftotext (poppler) or convert the PRD to markdown."`

4. Compute the PRD content hash for the scaffold-metadata footer:
   ```bash
   PRD_SHA=$(shasum -a 256 "$PRD_PATH" | awk '{print $1}')
   ```

## Read inputs

- Load the PRD into context. If `.pdf`, run `pdftotext -layout "$PRD_PATH" -` and capture stdout.
- If `--screens <DIR>` provided: list filenames (one per line) and read 1–2 representative ones (smallest by file size, or first alphabetically) so context isn't blown.
- Read the project preset from `ritual.config.yaml`'s gate commands as a hint (e.g., `pnpm` → JS/TS monorepo; `uv` → Python; `go` → Go).

## Dispatch the masterplan-scaffolder subagent

Use the Agent tool with `subagent_type: masterplan-scaffolder`. Pass these fields in a structured prompt (no chat history; the subagent must work from this prompt alone):

```
PRD content:
<full PRD text>

Screens (optional):
<list of screen filenames; 1-2 sample images attached if --screens was provided>

Project preset hint:
<pnpm-monorepo | npm-single | python-uv | go-modules | blank>

Prefix hint (optional):
<comma-separated prefix letters from --prefix-hint, or empty>

Required output: a JSON document with these top-level keys:

{
  "prefixes": [
    {
      "id": "FE",
      "name": "Frontend",
      "ux": true,
      "gates": ["format", "lint", "typecheck", "test", "build"],
      "pre_build_plan_gate": false,
      "rationale": "PRD §3 covers user-facing screens..."
    },
    ...
  ],
  "tasks": [
    {
      "id": "FE-1",
      "title": "Login screen",
      "prefix": "FE",
      "deps": [],
      "prd_refs": "§3.1",
      "rationale": "Foundational UI before authenticated flows..."
    },
    ...
  ],
  "non_negotiables": [
    {
      "id": "auth-isolation",
      "title": "User identity isolation",
      "applies_to": ["BE", "FE"],
      "severity": "blocker",
      "summary": "Never leak one user's data to another...",
      "security": true
    },
    ...
  ]
}

Heuristics:
- Propose 3–8 prefixes (more is unwieldy).
- Group: UX-facing prefixes get ux: true; backend/infra get ux: false.
- pre_build_plan_gate: true only for prefixes whose tasks routinely warrant a plan-design step (e.g. agent flows, new screen designs).
- Tasks: 1 sentence titles, link to PRD §; 8-30 tasks total for a typical PRD.
- Deps: only when a task genuinely cannot start without another's output.
- non_negotiables: pull from PRD's "must" / "must not" / "never" rules. Keep summaries 1-2 sentences. severity: blocker for hard rules, major for guidelines. security: true when the rule guards auth, payments, RLS, or secrets.
```

The reviewer-style subagent runs cleanly because its inputs are self-contained.

## Render drafts

When the subagent returns the JSON:

1. Render `MASTERPLAN.md.draft`:
   ```markdown
   # <project name> — MASTERPLAN

   | Phase | ID | Task | Status | Deps | PRD-refs |
   |-------|----|------|--------|------|----------|
   | <prefix> | <ID> | <title> | todo | <dep1, dep2> | <§ref> |
   ...
   ```

2. Render `ritual.config.yaml.draft` by **merging** the subagent's `prefixes[]` and `non_negotiables[]` into the existing config (preserve `paths:`, `gates:`, `git:`, `commit:`, `walk:`, `hooks:`).

3. Render `reviewer.project.md.draft` (write to `.claude/ritual/reviewer.project.md.draft`):
   ```markdown
   # Project reviewer rules

   For each rule, the reviewer checks if the task's prefix is in `applies_to`.
   If yes, it walks the diff and reports Pass/Fail with file:line evidence.
   Severity `blocker` → fail. `major` → flag but allow Pass.

   ## Rules

   ### <id> — <severity>
   **Applies to:** <prefix list>
   **Summary:** <summary>

   ...
   ```

## Display proposal

Show the operator (in this exact order):

```
## Scaffold proposal

### Prefix taxonomy (<n> prefixes)

| ID | Name | UX | Gates | Plan gate | Rationale |
|----|------|----|----|----|---------|
| FE | Frontend | ✓ | format, lint, typecheck, test, build | – | PRD §3 covers user-facing screens |
...

### Task list (<n> tasks)

**<prefix>** (<count>): <first 3 task titles, "..." if more>
...

### Non-negotiables (<n> rules)

- <id> — <severity> — applies to <prefixes> — <one-line summary>
...

### PRD source
- Path: <PRD-PATH>
- SHA-256: <prd_sha>

Confirm with: y / e (edit) / n
```

## Confirmation prompt

- **`y`**:
  1. `mv MASTERPLAN.md.draft MASTERPLAN.md`
  2. `mv ritual.config.yaml.draft ritual.config.yaml`
  3. `mv .claude/ritual/reviewer.project.md.draft .claude/ritual/reviewer.project.md`
  4. For each task in `tasks[]`, write `.taskstate/<ID>.json`:
     ```json
     {
       "id": "FE-1",
       "status": "todo",
       "branch": null,
       "worktree": null,
       "pr": null,
       "commit": null,
       "updated_at": "<ISO-8601 now>",
       "follow_ups": []
     }
     ```
  5. Append the scaffold-metadata footer to `MASTERPLAN.md`:
     ```html
     <!-- scaffolded: from=<PRD-PATH>, on=<ISO-date>, ritual_version=<ver>, prd_sha=<prd_sha> -->
     ```
  6. Append a single anchored entry to `BUILDLOG.md`:
     ```markdown
     <!-- TASK:INIT:START -->
     ## INIT — scaffold from <PRD-PATH>

     - Date: <ISO-date>
     - PRD SHA-256: <prd_sha>
     - Prefixes: <prefix list>
     - Tasks created: <count>
     - Non-negotiables: <count>
     <!-- TASK:INIT:END -->
     ```
  7. Stage all changed files: `git add MASTERPLAN.md ritual.config.yaml .claude/ritual/reviewer.project.md .taskstate/ BUILDLOG.md`
  8. Commit on `main` with message:
     ```
     chore: scaffold masterplan from <PRD-PATH>

     Generated by /plan-init from <PRD-PATH> (sha256 <first 8 chars>).
     <n> prefixes, <n> tasks, <n> non-negotiables.
     ```
     The `guard-main.sh` hook permits `chore:` commits on main per its allow-list.

  Tell the operator: `"Scaffolded. Run /plan-next to pick the first task."`

- **`e`** (edit): open `MASTERPLAN.md.draft` in `$EDITOR` (fallback `vi`). After save, redisplay the (now edited) draft summary and re-prompt. Allow up to 3 edit cycles before forcing y/n.

- **`n`**: keep `.draft` files for inspection (operator can compare or run `--dry-run` again). Exit non-zero with: `"Scaffold rejected. Review the .draft files; re-run /plan-init to regenerate."`

## Dry-run mode

If `--dry-run` was passed, stop after rendering the drafts and displaying the proposal. Do not prompt for confirmation; do not write `.taskstate/`, `MASTERPLAN.md`, or commit.

## Never

- Never overwrite a non-empty `MASTERPLAN.md` or a populated `prefixes:` block. The has-prefixes preflight is the safety gate.
- Never commit if any draft rendering step failed. Bail and leave drafts for inspection.
- Never bias the scaffolder with chat history. The subagent prompt is self-contained.
- Never invent PRD content. The scaffolder works from what the PRD says; if the PRD is silent on something, that's a `Silent` finding, not a fabrication.

## Edge cases

- **PRD < 200 words**: stop with `"PRD is too thin to scaffold a useful plan. Add §-numbered sections and try again."`
- **PRD > ~30 pages**: warn `"Long PRDs sometimes scaffold incompletely. Consider splitting per major area and running /plan-init per section."` and proceed.
- **No "must" / "should" / "never" language found**: emit `non_negotiables: []`. The reviewer.project.md.tmpl placeholder remains.
- **Scaffolder returns malformed JSON**: bail with the JSON error; do not write any drafts.
