# Security

## What is exposed

| Surface | Who can reach it | Protection |
|---|---|---|
| The web app and its API (`app`'s domain) | anyone | Auth.js sessions (JWT, `__Secure-` cookies over HTTPS), per-route checks upstream |
| Public prompts, profiles, the MCP endpoint's read tools | anyone | By design: a prompt library is browsable without an account |
| Private prompts | the author (and admins in the admin panel) | Upstream's checks (`/api/prompts/:id` answers 403); tested |
| Admin panel and `/api/admin/*` | role `ADMIN` | Every handler checks the role (reviewed); tested for anonymous visitors and members |
| `/api/cron/reset-credits` | holders of `CRON_SECRET` | Bearer secret, generated |
| MCP write tools (`/api/mcp`) | holders of a user's API key | Keys generated per user in settings; rate-limited upstream |
| PostgreSQL | the private network only | No public domain or TCP proxy; generated password |

## Defaults this template changes

- **Sign-up closed on every path** (see `ARCHITECTURE.md`, "The sign-up gate"). Upstream's switch leaves OAuth
  sign-ups open, and its Docker default is open e-mail registration.
- **No default admin.** Upstream's seed script creates `admin@prompts.chat` and every contributor with the password
  `password123`; this template never runs it. The owner gets a generated password, and imported contributors are
  placeholders without passwords, which the gate enforces.
- **No Sentry.** Upstream's configuration sends errors, request data, user PII and 10% of sessions as replays to
  prompts.chat's Sentry project from every self-hosted instance.
- **A stable `AUTH_SECRET` is required**, not silently generated.
- **Dependency advisories.** Upstream's lockfile at the pinned commit has 5 critical and 20 high production
  advisories (`npm audit --omit=dev`), including Next.js 16.1.0 and next-auth 5.0.0-beta.30 (an authentication check
  that can fail open). `images/app/deps` resolves them to Next.js 16.3.5, next-auth 5.0.0-beta.32, @auth/core 0.41.3
  and sharp 0.35.4.

## Residual risks

- **E-mail sign-up does not verify addresses.** Upstream has no e-mail at all. With an `@domain` entry and the form
  open, anyone who can reach the site can create an account under any address at that domain. Prefer GitHub or
  Google sign-in for domain entries, or list exact addresses and close the form after your team has joined.
- **Remaining advisories**: Prisma's CLI (`@prisma/config` → `effect`, `deepmerge-ts`; used only for migrations,
  with the image's own schema), and DOMPurify (moderate) inside the Monaco editor in the browser. `npm audit` offers
  only a Prisma downgrade.
- **The health endpoint** returns the database error message when the database is unreachable (upstream behaviour),
  which can include the database host name.
- **Next.js image optimisation** accepts any HTTPS host (`remotePatterns: **`, upstream), so `/_next/image` fetches
  arbitrary public images.
- **Webhooks** configured by an admin are sent to any URL the admin enters.
- **Imported library data** is upstream's public CSV; some contributor names in it are e-mail addresses.
- **Passwords cannot be changed or reset in the app** (upstream has no such feature and sends no e-mail). The owner's
  password lives in the `app` service's variables, readable by anyone with access to the Railway project; change it
  there with `OWNER_RESET_PASSWORD=true` and a redeploy. A member who forgets their password can only be deleted by
  an admin and sign up again.

## Reporting

Report problems with this template in the repository's issues without secrets or personal data. Report
vulnerabilities in prompts.chat itself to the upstream project (its `SECURITY.md`).
