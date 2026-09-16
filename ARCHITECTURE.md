# Architecture

## Services

```
browser ──HTTPS──> app (prompts.chat, Next.js, :3000) ──private network──> db (PostgreSQL 17, volume)
```

| Service | Image | Public | Volume | Notes |
|---|---|---|---|---|
| `app` | `ghcr.io/youssefsiam38/promptschat-railway` | yes, port 3000 | none | Stateless; healthcheck `/api/health` (answers 200 only with a working database) |
| `db` | `postgres:17.11-bookworm` | no | `/var/lib/postgresql/data` | `PGDATA` one level down, because Railway volumes hold `lost+found` at their root |

`app` reaches `db` at `db.railway.internal` through `DATABASE_URL`, built from `db`'s variables. The app listens on
`::` (both address families), so Railway's edge and private network both reach it.

## Image

`images/app/Dockerfile` builds upstream's pinned commit in five stages:

1. **fetch**: the exact commit, verified, and upstream's `package.json` and lockfile checked against recorded hashes.
2. **source**: `patch-source.mjs` applies the build-time changes, each to a file whose hash is checked first; then
   the dependency fixes (`images/app/deps`) and the base configuration (`prompts.config.ts`) are copied in.
3. **builder**: `npm ci` and `next build` (standalone output). The build fails if upstream's Sentry DSN or the
   sponsored widgets survive in the output.
4. **runtime-deps**: Prisma's CLI and bcryptjs from their own lockfile (`images/app/runtime`), with Prisma's schema
   engine downloaded at build time.
5. **final**: Node 24 on Debian bookworm, running as `node`, with the standalone app, the migrations and the CC0
   `prompts.csv`.

## Start-up

`entrypoint.sh`:

1. Refuses to start without `DATABASE_URL`, an `AUTH_SECRET` of at least 32 characters, `OWNER_EMAIL` and
   `OWNER_PASSWORD`. (Upstream generates a random `AUTH_SECRET` when it is missing, which signs everyone out at
   every restart.) `DIRECT_URL` defaults to `DATABASE_URL`.
2. Waits for PostgreSQL to accept connections (up to three minutes).
3. Applies upstream's Prisma migrations (`prisma migrate deploy`), retrying while a fresh database finishes starting.
4. Hands over to `start.mjs`.

`start.mjs`:

1. Creates the `railway_template` schema (outside upstream's `public` schema): a `state` table, a `settings`
   table, and the sign-up gate (below). Writes the sign-up policy from `PCHAT_ALLOW_REGISTRATION` and
   `PROMPTS_ALLOWED_SIGNUPS`.
2. **Owner.** If no account has `OWNER_EMAIL`, creates it with role `ADMIN`, the bcrypt hash of `OWNER_PASSWORD`,
   and username `OWNER_USERNAME` (default `owner`, or the next free variant). If it exists, makes sure it is
   `ADMIN` and has a password; the password itself changes only with `OWNER_RESET_PASSWORD=true`.
3. Starts the app (`node server.js`) as a child process and forwards `SIGTERM`/`SIGINT` to it.
4. **Library import**, once the app is healthy: signs in as the owner through Auth.js exactly as the login form
   does, and calls upstream's admin import (`POST /api/admin/import-prompts`), which reads `prompts.csv`. The
   `library_import` state goes `started` then `done`; an interrupted import is resumed at the next start (the import
   skips titles that already exist). A database that already holds prompts is marked `skipped` and never touched.
5. **Credit reset**: every day at 00:00 UTC it calls `POST /api/cron/reset-credits` with `CRON_SECRET`, which
   upstream expects an external cron to do.

## The sign-up gate

prompts.chat creates accounts in three places: its e-mail sign-up API, the Auth.js adapter when someone signs in
with GitHub, Google or another OAuth provider for the first time, and the same adapter "claiming" a contributor
placeholder by changing its e-mail address. Upstream's `allowRegistration` covers only the first.

A `BEFORE INSERT OR UPDATE OF email` trigger on `public.users` covers all three:

| Case | Result |
|---|---|
| The owner's creation by `start.mjs` (transaction-local `promptschat.bootstrap` setting) | admitted |
| A contributor placeholder from the library import: `…@unclaimed.prompts.chat` **and no password** | admitted |
| `PROMPTS_ALLOWED_SIGNUPS` set | admitted only if the address equals an entry, or its domain equals an `@domain` entry exactly (no subdomains) |
| `PROMPTS_ALLOWED_SIGNUPS` empty | admitted only if `PCHAT_ALLOW_REGISTRATION` is true |
| An e-mail change on an existing real account | not gated |

A refusal raises `promptschat_signup_not_allowed`. A build-time patch makes the sign-up API answer 403
`signup_not_allowed` for it; an OAuth sign-in shows Auth.js's error page.

`PCHAT_ALLOW_REGISTRATION` is parsed exactly as upstream parses it (`true` or `1`), so the form and the database
always agree.

## Build-time changes to upstream

| File | Change | Why |
|---|---|---|
| `sentry.server.config.ts`, `sentry.edge.config.ts`, `src/instrumentation-client.ts`, `src/instrumentation.ts` | emptied | They initialise Sentry with prompts.chat's DSN, PII and session replay |
| `next.config.ts` | `withSentryConfig` wrapper removed | Source-map upload and the build plugin's telemetry |
| `src/lib/plugins/widgets/index.ts` | widget list emptied | Sponsored cards (affiliate links) injected into prompt lists |
| `src/app/api/auth/register/route.ts` | 403 for the gate's refusal | Instead of a generic 500 |
| `src/app/layout.tsx` | titles from `PCHAT_NAME`; cookie banner only with `GOOGLE_ANALYTICS_ID` | Upstream names prompts.chat whatever the branding, and asks analytics consent with no analytics |
| `src/__tests__/` | removed | Unit-test mocks no longer type-check against the fixed next-auth; not part of the app |
| `prompts.config.ts` | replaced | Upstream's is prompts.chat's own (GitHub, Google and Apple sign-in, sponsors); see `images/app/prompts.config.ts` |
| `package.json`, `package-lock.json` | replaced by `images/app/deps` | Non-breaking advisory fixes; `sharp` 0.33 → 0.35, Prisma 6.19.1 → 6.19.3 |
