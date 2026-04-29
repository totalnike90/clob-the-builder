# Greenfield Next.js Example

A minimal Next.js skeleton with a seed `docs/PRD.md`, used to demonstrate `clob-the-builder` end-to-end.

## Run the demo

```bash
# 1. Clone clob-the-builder somewhere persistent.
git clone https://github.com/totalnike90/clob-the-builder.git ~/code/clob-the-builder

# 2. Copy this example to a fresh location and turn it into a git repo.
cp -R /path/to/clob-the-builder/examples/greenfield-nextjs ~/my-test-project
cd ~/my-test-project
git init && git add . && git commit -m "chore: init from clob-the-builder example"

# 3. Install the ritual.
bash ~/code/clob-the-builder/install.sh

# 4. Open Claude Code in this repo, then run:
/plan-init docs/PRD.md

# 5. After confirming the scaffold, the loop is unlocked:
/plan-next
/build <ID>      # replace <ID> with the first proposed task
/walk <ID>
/check <ID>
/review <ID>
/ship <ID>
```

## What's in here

- `package.json` — Next.js scripts: `dev`, `build`, `lint`, `typecheck`, `test`, `format:check`.
- `docs/PRD.md` — the seed PRD: a tiny "greeter app" spec with §-numbered sections, normative rules, and clear acceptance criteria. Designed to scaffold cleanly into 5–10 tasks across `FE-*` and `BE-*` prefixes.
- `app/page.tsx` — placeholder home page.
- (Everything else gets created by `install.sh` + `/plan-init`.)

## Why this exists

Two purposes:

1. **Documentation by example** — readers can see exactly what `clob-the-builder` adds to a clean project.
2. **Regression fixture** — `tests/install.bats` runs `install.sh` against this skeleton and asserts the expected files appear.
