# Upstream

| Component | Pinned | Source |
|---|---|---|
| prompts.chat | commit `f78a1c5136fa080155d928e0d7e2b4a41ddef03e` (2026-09-09) | https://github.com/f/prompts.chat |
| Node.js base | `node:24.21.0-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553` | Docker Hub official image |
| Git (fetch stage) | `alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26` | Docker Hub |
| PostgreSQL | `postgres:17.11-bookworm` (compose also pins `@sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0`) | Docker Hub official image |
| Prisma CLI, bcryptjs (start-up) | 6.19.3, 3.0.3 (`images/app/runtime/package-lock.json`) | npm |

prompts.chat has no releases or version tags; its only images are the moving `ghcr.io/f/prompts.chat:main` and
`:latest`. This repository builds a pinned commit instead.

## Upstream files the build checks

| File | sha256 at the pinned commit |
|---|---|
| `package.json` | `83cf317e9fb936a0f96dcc58e843a525f59658ce6cf2de1884f7b3b54b232894` |
| `package-lock.json` | `dce5362d82b2fefe076a397563d69c4f80e50afd3370e0fdfdd3895dda5d96ae` |
| Every file `images/app/patch-source.mjs` changes | listed in its `EXPECTED` table |

## What this repository changes

See `ARCHITECTURE.md`, "Build-time changes to upstream". In short: Sentry removed, sponsored widgets removed, page
titles and the cookie banner follow the deployment, the sign-up API reports the gate's refusal as 403, a
self-hosting `prompts.config.ts`, upstream's unit tests dropped from the build, and dependency fixes.

## Dependency fixes (`images/app/deps`)

Made from upstream's manifests with `npm audit fix --package-lock-only`, plus `sharp` `^0.35.4` and Prisma
`^6.19.3`. Notable resolutions:

| Package | Upstream lockfile | Here |
|---|---|---|
| next | 16.1.0 | 16.3.5 |
| next-auth | 5.0.0-beta.30 | 5.0.0-beta.32 |
| @auth/core | 0.41.1 | 0.41.3 |
| sharp | 0.33.5 | 0.35.4 |
| prisma, @prisma/client | 6.19.1 | 6.19.3 |
| @modelcontextprotocol/sdk | 1.25.1 | 1.30.0 |

`npm audit --omit=dev` afterwards: 0 critical, 3 high (all Prisma's CLI configuration loader), 1 moderate, 1 low.
