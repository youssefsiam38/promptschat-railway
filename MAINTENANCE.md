# Maintenance

## Release process

1. Make the change on a branch. The `test` workflow builds the image and runs the full suite on every push and pull
   request.
2. Run locally:
   ```bash
   docker compose build --pull
   tests/static.sh && tests/smoke.sh && tests/persistence.sh
   ```
3. Tag `vX.Y.Z`. The `publish-image` workflow builds the image as a local candidate, runs the smoke and persistence
   suites against it, and only then retags and pushes that exact image to GHCR as `X.Y.Z`, `X.Y` and `latest`.
4. Update the Railway template (id in `RAILWAY_TEMPLATE.md`): the `app` image tag, with `templateChangeSetStage`
   then `templateChangeSetApply`. Tags only. Republish the overview with
   `railway templates update <id> --readme-file marketplace/OVERVIEW.md` if it changed. Never put angle-bracket
   placeholders in the overview or variable descriptions: Railway strips them.
5. Deploy the updated template into a scratch project and run
   ```bash
   OWNER_EMAIL=... OWNER_PASSWORD_FILE=... CRON_SECRET_FILE=... tests/railway-smoke.sh https://APP-DOMAIN
   ```
   then set `PCHAT_ALLOW_REGISTRATION=true` and `PROMPTS_ALLOWED_SIGNUPS=@railway-smoke.test` on `app`, redeploy it,
   run again with `PROMPTSCHAT_SMOKE_PHASE=allowlist`, redeploy `db` and `app`, run once more, and delete the scratch
   project.

## Bumping prompts.chat

1. Read the commits between the pinned commit and the candidate, especially `prisma/`, `src/lib/auth`,
   `src/lib/plugins/auth`, `src/app/api/auth`, `src/app/api/admin/import-prompts`, `src/lib/config`, the Sentry
   files, `next.config.ts`, `docker/` and `package.json`.
2. Change `ARG PROMPTSCHAT_COMMIT` in `images/app/Dockerfile`.
3. If `package.json` or the lockfile changed, the build stops at the hash check: regenerate `images/app/deps`
   (`npm audit fix --package-lock-only` on upstream's files, then the `sharp` and Prisma bumps if still needed),
   update the two hashes, and keep `images/app/runtime` on the same Prisma and bcryptjs versions (`tests/static.sh`
   checks).
4. If a patched file changed, `patch-source.mjs` stops with its new hash: re-read the file, adjust the patch, and
   record the new hash.
5. Build and run the suites.

### Breaking-change checklist

- [ ] New ways to create users (another auth plugin, an admin "create user" API, invitations): the gate covers every
      insert into `users`, but check the new path's error handling and add a test.
- [ ] The `users` table renamed, or `email`/`password` columns changed: update the trigger in `start.mjs`.
- [ ] The contributor placeholder domain (`unclaimed.prompts.chat`) or the import's CSV columns changed: update the
      gate and `tests/smoke.sh`.
- [ ] `POST /api/admin/import-prompts` moved or its response changed: update `importLibrary` in `start.mjs`.
- [ ] Auth.js cookie names or the credentials callback changed: `signInAsOwner` in `start.mjs` and `sign_in` in
      `tests/lib.sh`.
- [ ] New telemetry, analytics or third-party scripts: extend `patch-source.mjs` and the checks in the Dockerfile.
- [ ] New PCHAT_* variables: document them in `README.md`.

## Rollback

Point the template's `app` image back at the previous tag. Prisma migrations are forward-only: if a release
applied a new migration, restore the database from a backup taken before the upgrade (Railway volume backups, or
`pg_dump` from `db`) rather than running an older image against a newer schema.
