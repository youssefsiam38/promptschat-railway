#!/bin/sh
# prompts.chat start-up: check the configuration, wait for PostgreSQL, apply upstream's migrations, then hand
# over to start.mjs (owner account, the app itself, the prompt library import and the daily credit reset).
# Secrets are never printed; only their names and whether they are usable.
set -eu

log() { printf '[promptschat-railway] %s\n' "$*"; }
die() { printf '[promptschat-railway] ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set."
# schema.prisma reads DIRECT_URL for migrations; without a connection pooler it is the same database.
: "${DIRECT_URL:=$DATABASE_URL}"
export DIRECT_URL

# Upstream generates a random AUTH_SECRET when it is missing, which signs everyone out at every restart.
[ -n "${AUTH_SECRET:-}" ] || die "AUTH_SECRET is not set. It signs sessions; set it to a random value of at least 32 characters."
[ "${#AUTH_SECRET}" -ge 32 ] || die "AUTH_SECRET is too short (${#AUTH_SECRET} characters); use at least 32."
[ -n "${OWNER_EMAIL:-}" ] || die "OWNER_EMAIL is not set. It is the e-mail address of the owner account."
[ -n "${OWNER_PASSWORD:-}" ] || die "OWNER_PASSWORD is not set."

log "prompts.chat ${PROMPTSCHAT_COMMIT:-unknown}"
log "waiting for the database..."
tries=0
until node -e '
  const net = require("net");
  const url = new URL(process.env.DATABASE_URL);
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const sock = net.createConnection({ host, port: Number(url.port) || 5432 });
  sock.setTimeout(3000);
  sock.on("connect", () => { sock.destroy(); process.exit(0); });
  sock.on("timeout", () => { sock.destroy(); process.exit(1); });
  sock.on("error", () => process.exit(1));
' 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 90 ] || die "the database did not accept connections within three minutes."
  sleep 2
done

log "applying database migrations..."
# PostgreSQL can accept connections for a moment before it accepts logins after a first initialisation.
attempt=1
until (cd /opt/promptschat/runtime && node node_modules/prisma/build/index.js migrate deploy --schema /app/prisma/schema.prisma); do
  [ "$attempt" -lt 10 ] || die "migrations failed."
  attempt=$((attempt + 1))
  log "migrations did not apply; retrying in 5s (attempt ${attempt}/10)"
  sleep 5
done

exec node /opt/promptschat/start.mjs
