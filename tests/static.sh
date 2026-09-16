#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Static validation: syntax, shellcheck, compose, pins, the source patches and the security defaults. No Docker build.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
cd "$REPO_ROOT"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

section "syntax"
for f in images/app/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in images/app/*.mjs; do
  if node --check "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
if sh -n images/app/entrypoint.sh; then pass "entrypoint is POSIX sh"; else fail "entrypoint is not POSIX sh"; fi

section "shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck -s sh images/app/entrypoint.sh; then pass "shellcheck entrypoint"; else fail "shellcheck entrypoint"; fi
  if shellcheck -x -s bash tests/*.sh; then pass "shellcheck tests"; else fail "shellcheck tests"; fi
else
  echo "  SKIP  shellcheck not installed"
fi

section "compose"
if docker compose -f compose.yaml config -q; then pass "compose config"; else fail "compose config"; fi
cfg=$(docker compose -f compose.yaml config --format json)
assert_eq "two services" "app db" "$(jq -r '[.services | keys[]] | sort | join(" ")' <<<"$cfg")"
assert_eq "only the app publishes a port" "app" "$(jq -r '[.services | to_entries[] | select(.value.ports) | .key] | join(" ")' <<<"$cfg")"
assert_eq "the port binds to loopback" "127.0.0.1" "$(jq -r '[.services[] | .ports[]? | .host_ip] | join(" ")' <<<"$cfg")"
assert_contains "PostgreSQL pinned by tag and digest" '^docker.io/library/postgres:17\.[0-9]*-bookworm@sha256:[0-9a-f]\{64\}$' "$(jq -r '.services.db.image' <<<"$cfg")"
assert_eq "PGDATA below the volume root (Railway volumes hold lost+found)" "/var/lib/postgresql/data/pgdata" "$(jq -r '.services.db.environment.PGDATA' <<<"$cfg")"
assert_eq "local sign-up defaults to closed" "false" "$(jq -r '.services.app.environment.PCHAT_ALLOW_REGISTRATION' <<<"$cfg")"

section "image pins"
df=images/app/Dockerfile
for arg in GIT_IMAGE NODE_IMAGE; do
  assert_contains "$arg pinned by digest" "^ARG $arg=.*@sha256:[0-9a-f]\{64\}$" "$(grep "^ARG $arg=" "$df")"
done
assert_contains "an exact upstream commit" '^ARG PROMPTSCHAT_COMMIT=[0-9a-f]\{40\}$' "$(grep '^ARG PROMPTSCHAT_COMMIT=' "$df")"
assert_contains "the build verifies the fetched commit" 'test "$(git -C /src rev-parse HEAD)" = "${PROMPTSCHAT_COMMIT}"' "$(cat "$df")"
assert_contains "the build checks upstream's manifests" 'UPSTREAM_PACKAGE_LOCK_SHA256}  /src/package-lock.json" | sha256sum -c -' "$(cat "$df")"
assert_contains "the build fails if upstream's Sentry DSN survives" "o4510673866063872" "$(grep -A3 'RUN npm run build' "$df")"
node_version=$(grep '^ARG NODE_IMAGE=' "$df" | sed -E 's/.*node:([0-9]+)\..*/\1/')
assert_eq "Node major matches upstream's engines field" "$(jq -r '.engines.node' images/app/deps/package.json | tr -d 'x.')" "$node_version"

section "dependency fixes"
deps=images/app/deps
assert_eq "lockfile belongs to the manifest" "$(jq -r '.name' "$deps/package.json")" "$(jq -r '.name' "$deps/package-lock.json")"
for pkg in next next-auth @auth/core sharp prisma @prisma/client; do
  want=$(jq -r --arg p "$pkg" '.dependencies[$p] // .devDependencies[$p] // empty' "$deps/package.json")
  got=$(jq -r --arg p "node_modules/$pkg" '.packages[$p].version' "$deps/package-lock.json")
  [ -n "$got" ] && [ "$got" != null ] && pass "$pkg locked at $got (wanted $want)" || fail "$pkg missing from the lockfile"
done
ver() { jq -r --arg p "node_modules/$1" '.packages[$p].version' "$deps/package-lock.json"; }
gte() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
gte "$(ver next)" 16.3.5 && pass "Next.js is at a fixed release ($(ver next))" || fail "Next.js below 16.3.5"
gte "$(ver next-auth | sed 's/-beta\./.0./')" 5.0.0.0.32 && pass "next-auth fixed ($(ver next-auth))" || fail "next-auth below beta.32"
gte "$(ver sharp)" 0.35.4 && pass "sharp fixed ($(ver sharp))" || fail "sharp below 0.35.4"
assert_eq "runtime Prisma CLI matches the app's Prisma" "$(ver prisma)" "$(jq -r '.packages["node_modules/prisma"].version' images/app/runtime/package-lock.json)"
assert_eq "runtime bcryptjs matches the app's" "$(ver bcryptjs)" "$(jq -r '.packages["node_modules/bcryptjs"].version' images/app/runtime/package-lock.json)"

section "source patches"
p=images/app/patch-source.mjs
assert_eq "every patched file is hash-checked" "8" "$(grep -cE '^  "[^"]+": "[0-9a-f]{64}",$' "$p")"
assert_contains "Sentry configuration emptied" 'write("sentry.server.config.ts", NO_SENTRY)' "$(cat "$p")"
assert_contains "Sentry build wrapper removed" 'export default withMDX(withNextIntl(nextConfig));' "$(cat "$p")"
assert_contains "sponsored widgets removed" 'const widgetPlugins: WidgetPlugin\[\] = \[\];' "$(cat "$p")"
cfgts=images/app/prompts.config.ts
assert_contains "base config: e-mail and password only" 'providers: \["credentials"\]' "$(cat "$cfgts")"
assert_contains "base config: registration closed" 'allowRegistration: false' "$(cat "$cfgts")"
assert_contains "base config: clone branding" 'useCloneBranding: true' "$(cat "$cfgts")"
assert_not_contains "base config: no sponsor entries" 'utm_source' "$(cat "$cfgts")"

section "start-up security"
e=images/app/entrypoint.sh
assert_contains "refuses to start without AUTH_SECRET" 'AUTH_SECRET is not set' "$(cat "$e")"
assert_contains "refuses a short AUTH_SECRET" 'AUTH_SECRET is too short' "$(cat "$e")"
assert_contains "refuses to start without an owner" 'OWNER_EMAIL is not set' "$(cat "$e")"
s=images/app/start.mjs
assert_contains "the sign-up trigger covers inserts and e-mail changes" 'BEFORE INSERT OR UPDATE OF email ON public.users' "$(cat "$s")"
assert_contains "placeholders are admitted only without a password" "NEW.password IS NULL" "$(cat "$s")"
assert_contains "owner creation is the only bypass, per transaction" "set_config('promptschat.bootstrap', 'on', true)" "$(cat "$s")"
assert_contains "PCHAT booleans parsed exactly like upstream" 'v.toLowerCase() === "true" || v === "1"' "$(cat "$s")"
leaks=$(grep -nE '(log|warn|console\.(log|warn|error))\(.*(OWNER_PASSWORD|AUTH_SECRET|CRON_SECRET|OWNER_EMAIL|DATABASE_URL)\b[^"`]*\)' "$s" "$e" | grep -vE 'is not set|too short|is on|is off|is not an e-mail' || true)
assert_eq "no log line prints a secret or the owner's address" "" "$leaks"

section "secrets hygiene"
mapfile -t tracked < <(git ls-files 2>/dev/null | grep . || find . -type f -not -path './.git/*' -not -path './test-output/*')
if [ "${#tracked[@]}" -gt 0 ] && grep -lE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "${tracked[@]}" 2>/dev/null; then
  fail "a credential-shaped string is in the repository"
else
  pass "no credential-shaped strings in ${#tracked[@]} files"
fi

summary
