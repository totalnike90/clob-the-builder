# Greenfield Next.js Example — PRD

A minimal product spec used to demonstrate `clob-the-builder`'s `/plan-init`
flow on a brand-new Next.js project. Replace this file with your real PRD
when you copy this skeleton into your own repo.

## §1. Vision

Build a small, fast greeter app that asks for a name and personalises the
greeting. The app demonstrates the full ritual end-to-end on a tiny
codebase so contributors can validate `clob-the-builder` install →
`/plan-init` → `/plan-next` → `/build` → `/walk` → `/check` → `/review` →
`/ship` without the noise of a real product.

## §2. Users

Two roles:

- **Visitor** — anyone who lands on the home page. Enters their name; sees
  a personalised greeting.
- **Admin** — single hardcoded admin (env var `ADMIN_EMAIL`) who can view
  a list of all greetings recorded today.

## §3. Features

### §3.1. Home page (UI)

- A single input field "What's your name?"
- A "Greet me" button.
- On submit, the app records the name + timestamp and shows
  `"Hi, <name>! Welcome."` underneath.

### §3.2. Recorded greetings (UI, admin only)

- An `/admin` page lists every recorded name + timestamp from today.
- Page is gated by an admin-only check; non-admins see a 404.

### §3.3. API (BE)

- `POST /api/greetings` accepts `{ name: string }` and returns
  `{ id: string, name: string, recorded_at: ISO-8601 }`. Validates that
  `name` is 1–100 chars; rejects with 400 otherwise.
- `GET /api/greetings/today` returns today's greetings (admin only).

### §3.4. Storage

- A single SQLite table `greetings(id, name, recorded_at)`. Created at
  app start if missing. Migrations live under `db/migrations/`.

## §4. Non-functional requirements

- The home page must render in < 100 KB JS first-load (mobile target).
- The API must respond in < 50 ms p99 on the dev machine.
- All tests must pass in < 5 s.

## §5. Non-negotiable rules

- **Admin isolation** — non-admin users **must not** be able to access
  `/api/greetings/today` or `/admin`. Verify with both unit tests and a
  manual /walk attempt.
- **Input validation** — all user input **must** be validated before any
  DB write. No `db.write(req.body.name)` without a length + type check.
- **No PII in logs** — the `name` field **must not** appear in any log
  output, including error logs.

## §6. Out of scope (for the greenfield example)

- Authentication / sessions beyond the hardcoded admin email.
- Email or notifications.
- Anything that needs a real backend (Postgres, Redis, queues).
- Internationalisation.

## §7. Acceptance

The greenfield example is "shipped" when:

- `bash clob-the-builder/install.sh` completes without errors.
- `/plan-init docs/PRD.md` populates MASTERPLAN.md with at least 5 tasks.
- `/plan-next` returns the first task without errors.
- The project's `prefixes:` block in `ritual.config.yaml` has at least 2
  prefixes (likely `FE-*` and `BE-*`).
