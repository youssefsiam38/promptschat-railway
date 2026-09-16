# prompts.chat on Railway

A community Railway template for [prompts.chat][upstream] (formerly Awesome ChatGPT Prompts), the open-source AI
prompt library: browse, search and copy prompts, write your own with versions and change requests, keep private
prompts, vote and comment, organise with categories, tags and collections, and use your library from AI tools over
MCP. It is not affiliated with the prompts.chat project.

This template runs your own library on Railway with PostgreSQL, **pre-filled with the CC0 prompts.chat collection
(about 2,000 prompts)**, an admin account for you, and sign-up closed until you decide who may join.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/prompts-chat)

## What you get

- **Two services**: the app (public) and PostgreSQL 17 with a volume, every secret generated at deploy time.
- **Your admin account** created at the first start from the e-mail you enter, with a generated password.
- **The prompt library imported once** at the first start, from the CC0 `prompts.csv` shipped in the image (no
  download from prompts.chat). Turn it off with `PROMPTS_IMPORT_LIBRARY=false`.
- **Sign-up closed by default, on every path.** Upstream's registration switch covers only e-mail sign-up, and a
  GitHub or Google sign-in admits anyone. Here the database refuses every new account unless you open registration
  or list the addresses and `@domains` allowed to join (`PROMPTS_ALLOWED_SIGNUPS`).
- **No telemetry.** Upstream's image reports errors, request data and session replays to prompts.chat's own Sentry
  project; this image is built without it. Sponsored cards in prompt lists and prompts.chat's sponsors, star
  counts and titles are gone too: the name in the header and page titles is yours (`PCHAT_NAME`).
- **Built from a pinned commit** with fixes for the published advisories in upstream's dependencies (Next.js,
  Auth.js, sharp), and tested in CI and on a live deployment of this template.
- The daily reset of AI generation credits runs inside the app; no external cron.

## First run

1. Deploy the template and enter `OWNER_EMAIL`.
2. Wait for `app` to go green (about a minute), then copy `OWNER_PASSWORD` from the `app` service's **Variables**.
3. Open the app's domain, **Login**, and sign in. The library import continues in the background for a minute or
   two; the prompt count on **Prompts** grows until it is done.
4. To let your team in, set `PROMPTS_ALLOWED_SIGNUPS` on `app` (for example `@yourcompany.com, a.friend@gmail.com`)
   and `PCHAT_ALLOW_REGISTRATION=true` to show the sign-up form, then redeploy `app`. See the note on e-mail
   verification below.

## Variables you may want to change

All on the `app` service. PCHAT_* variables are upstream's own runtime settings.

| Variable | Default | Meaning |
|---|---|---|
| `OWNER_EMAIL` | asked at deploy | The admin account's e-mail. |
| `OWNER_PASSWORD` | generated | The admin's first password. Changing it later does nothing unless `OWNER_RESET_PASSWORD=true`. |
| `OWNER_RESET_PASSWORD` | unset | `true` sets the admin's password to `OWNER_PASSWORD` at the next start; remove it afterwards. |
| `PROMPTS_ALLOWED_SIGNUPS` | unset | Comma-separated addresses and `@domain` entries that may create accounts, by any sign-in method. |
| `PCHAT_ALLOW_REGISTRATION` | `false` | `true` shows the sign-up form. With `PROMPTS_ALLOWED_SIGNUPS` empty it lets **anyone** join. |
| `PCHAT_NAME`, `PCHAT_DESCRIPTION`, `PCHAT_COLOR` | `Prompt Library` | Branding. |
| `PCHAT_LOCALES`, `PCHAT_DEFAULT_LOCALE` | all 17, `en` | Interface languages. |
| `PCHAT_AUTH_PROVIDERS` | `credentials` | Add `github` and/or `google` with `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` or `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`. Callback: `https://YOUR-DOMAIN/api/auth/callback/github` (or `google`). |
| `OPENAI_API_KEY`, `OPENAI_BASE_URL` | unset | For AI search and generation. |
| `PCHAT_FEATURE_AI_SEARCH`, `PCHAT_FEATURE_AI_GENERATION` | `false` | Turn the AI features on (need the key). After enabling search, generate embeddings from the admin panel. |
| `PCHAT_FEATURE_MCP`, `PCHAT_FEATURE_COMMENTS`, `PCHAT_FEATURE_PRIVATE_PROMPTS`, ... | `true` | Upstream's feature switches. |
| `PROMPTS_IMPORT_LIBRARY` | `true` | Import the CC0 library at the first start. It runs once, and never over an existing library. |
| `ENABLED_STORAGE`, `S3_*` | `url` | Media prompts take image URLs by default. For uploads, set `ENABLED_STORAGE=s3` and an S3-compatible, publicly readable bucket (`S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT`). |

## Persistent data

| Service | Path | Holds | If lost |
|---|---|---|---|
| `db` | `/var/lib/postgresql/data` | Accounts, prompts, versions, votes, comments, collections, API keys | Everything |

The app is stateless.

## Before you rely on it

- **The library is public to visitors.** Anyone who can reach the site can browse and search public prompts, as on
  prompts.chat; accounts are needed to write, vote and keep private prompts. Mark prompts private, or keep the
  domain to yourself.
- **E-mail sign-up does not verify addresses.** With `@yourcompany.com` allowed and the form open, anyone can sign
  up *as* any address at that domain. GitHub and Google sign-ins verify the address; prefer them for domain entries,
  or list exact addresses and close the form again once your team has joined.
- **No password changes or resets in the app**: prompts.chat has no such feature and sends no e-mail. Change the
  admin's password with a new `OWNER_PASSWORD` plus `OWNER_RESET_PASSWORD=true`; a member who forgets theirs has to
  be deleted by an admin and sign up again.
- **Imported contributors** appear as their GitHub names (some are e-mail addresses, as in upstream's public CSV).
  They are placeholder accounts without passwords.
- **AI features send prompt text to OpenAI** (or your `OPENAI_BASE_URL`).
- **Licence.** prompts.chat's code is MIT and its prompts CC0.

## Local development

```bash
docker compose build
tests/static.sh
tests/smoke.sh
tests/persistence.sh
```

The compose file mirrors the Railway services with fixed, public, local-test-only secrets and serves the app on
`http://localhost:13700` (`PROMPTSCHAT_TEST_PORT` moves it).

After deploying:

```bash
OWNER_EMAIL=you@example.com OWNER_PASSWORD_FILE=./owner-password tests/railway-smoke.sh https://YOUR-DOMAIN
```

## Documents

| File | Contents |
|---|---|
| `ARCHITECTURE.md` | Services, start-up, the sign-up gate, the library import |
| `SECURITY.md` | Threat model, what is exposed, residual risks |
| `RAILWAY_TEMPLATE.md` | The exact template configuration |
| `UPSTREAM.md` | Pinned versions, digests, and what this repository changes |
| `MAINTENANCE.md` | Release process, bumping upstream, rollback |
| `MARKETPLACE_AUDIT.md` | Why this template exists |
| `THIRD_PARTY_NOTICES.md` | Licences |

## Licence

MIT for this repository's own files. prompts.chat's source is MIT and its prompt content CC0; see
`THIRD_PARTY_NOTICES.md`.

[upstream]: https://github.com/f/prompts.chat
