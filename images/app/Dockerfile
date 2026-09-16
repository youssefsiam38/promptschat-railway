# syntax=docker/dockerfile:1
#
# prompts.chat for Railway: the app, built from a pinned upstream commit, plus the start-up that migrates the
# database, creates the owner, imports the prompt library and runs the daily credit reset.
#
# Upstream publishes only moving `main`/`latest` images, and those images report errors, request data and
# session replays to prompts.chat's own Sentry project. This image builds the pinned commit with:
#   - Sentry removed (patch-source.mjs), and sponsored cards removed from prompt lists;
#   - a self-hosting base configuration (prompts.config.ts): email and password sign-in, registration closed,
#     no prompts.chat achievements or sponsors on the home page. PCHAT_* variables still override it;
#   - package.json and the lockfile carrying non-breaking fixes for published advisories (images/app/deps; the
#     build first checks upstream's manifests are the ones those fixes were made from);
#   - Prisma's CLI (and bcryptjs, for the owner) from their own lockfile (images/app/runtime), not an unpinned install.
ARG GIT_IMAGE=docker.io/alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26
ARG NODE_IMAGE=docker.io/library/node:24.21.0-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553
ARG PROMPTSCHAT_COMMIT=f78a1c5136fa080155d928e0d7e2b4a41ddef03e
ARG UPSTREAM_PACKAGE_JSON_SHA256=83cf317e9fb936a0f96dcc58e843a525f59658ce6cf2de1884f7b3b54b232894
ARG UPSTREAM_PACKAGE_LOCK_SHA256=dce5362d82b2fefe076a397563d69c4f80e50afd3370e0fdfdd3895dda5d96ae

FROM ${GIT_IMAGE} AS fetch
ARG PROMPTSCHAT_COMMIT
ARG UPSTREAM_PACKAGE_JSON_SHA256
ARG UPSTREAM_PACKAGE_LOCK_SHA256
RUN git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/f/prompts.chat.git "${PROMPTSCHAT_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${PROMPTSCHAT_COMMIT}" \
    && rm -rf /src/.git \
    && echo "${UPSTREAM_PACKAGE_JSON_SHA256}  /src/package.json" | sha256sum -c - \
    && echo "${UPSTREAM_PACKAGE_LOCK_SHA256}  /src/package-lock.json" | sha256sum -c -

FROM ${NODE_IMAGE} AS source
COPY --from=fetch /src /src
COPY images/app/patch-source.mjs /tmp/patch-source.mjs
RUN node /tmp/patch-source.mjs /src
COPY images/app/deps/package.json images/app/deps/package-lock.json /src/
COPY images/app/prompts.config.ts /src/prompts.config.ts

FROM ${NODE_IMAGE} AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

FROM base AS builder
WORKDIR /build
# prisma generate runs on install and at build; nothing connects to this address. Puppeteer is a development
# dependency (book PDFs) whose install would download a browser nothing here uses.
ENV DATABASE_URL="postgresql://build:build@build.invalid:5432/build" \
    NEXT_TELEMETRY_DISABLED=1 \
    PUPPETEER_SKIP_DOWNLOAD=1
COPY --from=source /src/package.json /src/package-lock.json ./
COPY --from=source /src/prisma/schema.prisma prisma/schema.prisma
COPY --from=source /src/prisma.config.ts /src/tsconfig.json ./
RUN npm ci --no-audit --no-fund
COPY --from=source /src/ ./
# Upstream's Sentry DSN (organisation and key) must not survive in the build, nor the sponsored widgets. The Sentry
# SDK itself stays as a dependency of the two error pages and sends nothing without a DSN.
RUN npm run build \
    && ! grep -rqE 'o4510673866063872|9c2eb3b4441745efad28a908001c30bf' .next/standalone .next/static \
    && ! grep -rq 'coderabbit.link' .next/standalone/.next .next/static

FROM base AS runtime-deps
WORKDIR /opt/promptschat/runtime
COPY images/app/runtime/package.json images/app/runtime/package-lock.json ./
# Scripts run: Prisma downloads its schema engine here, at build time, not when the container starts.
RUN npm ci --omit=dev --no-audit --no-fund \
    && node node_modules/prisma/build/index.js --version | grep -q 'schema-engine'

FROM base
ARG PROMPTSCHAT_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

ENV NODE_ENV=production \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1 \
    AUTH_TRUST_HOST=true \
    PROMPTSCHAT_COMMIT=${PROMPTSCHAT_COMMIT}
WORKDIR /app

COPY --from=builder --chown=node:node /build/.next/standalone ./
COPY --from=builder --chown=node:node /build/.next/static ./.next/static
COPY --from=builder --chown=node:node /build/public ./public
COPY --from=source /src/prisma /app/prisma
# The admin panel's "import prompts" reads the CC0 library from the working directory.
COPY --from=source /src/prompts.csv /app/prompts.csv
COPY --from=runtime-deps /opt/promptschat/runtime /opt/promptschat/runtime
COPY images/app/start.mjs /opt/promptschat/start.mjs
COPY --chmod=0755 images/app/entrypoint.sh /usr/local/bin/promptschat-entrypoint
COPY licenses/ /usr/share/licenses/promptschat-railway/

RUN test -s /app/server.js \
    && test "$(ls /app/prisma/migrations | grep -c '^[0-9]')" -gt 0 \
    && test "$(head -1 /app/prompts.csv | tr -d "\r")" = "act,prompt,for_devs,type,contributor" \
    && cd /app && node -e 'require("@prisma/client")' \
    && cd /opt/promptschat/runtime && node -e 'require("bcryptjs")' \
    && node --check /opt/promptschat/start.mjs

USER node

LABEL org.opencontainers.image.title="promptschat-railway" \
      org.opencontainers.image.description="prompts.chat for the Railway template: built from a pinned commit without Sentry, with owner set-up, closed registration and the prompt library import. Not affiliated with prompts.chat." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/promptschat-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.promptschat-railway.upstream.commit="${PROMPTSCHAT_COMMIT}"

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/promptschat-entrypoint"]
