#!/usr/bin/env bash
# shellcheck disable=SC2015
# End-to-end smoke test of the local compose stack: start-up, owner, closed sign-up, the sign-up allowlist on
# both account paths, the prompt library import, prompts and their privacy, admin APIs, MCP, the credit reset
# and the owner password rules. Destroys and recreates the test stack's volumes.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
trap 'rm -rf "$TEST_TMP"' EXIT

OWNER_EMAIL=owner@example.test
printf '%s' local-test-only-owner-password > "$TEST_TMP/owner-pw"
IMAGE=$(compose config --format json | jq -r '.services.app.image')

# Recreate only the app with overridden variables and wait for it to serve again.
restart_app() {
  env "$@" docker compose -f "$REPO_ROOT/compose.yaml" up -d --force-recreate --no-deps app >/dev/null 2>&1
  wait_for_code "$APP_URL/api/health" 200 300 || die "app did not come back after a restart"
}

section "start-up"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d >/dev/null 2>&1 || die "compose up failed"
wait_for_code "$APP_URL/api/health" 200 || { compose logs --tail 80 app >&2; die "app never became healthy"; }
pass "health endpoint answers 200"
wait_for_log app 'created the owner account' 1 120 && pass "owner account created at first start" || fail "no owner creation in the log"
assert_contains "the database schema is migrated" 'users' "$(sql "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users'")"
assert_eq "the sign-up gate is installed on users" "railway_template_gate" "$(sql "SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.users'::regclass AND NOT tgisinternal")"
logs=$(compose logs --no-color app 2>/dev/null)
assert_contains "start-up reports sign-up closed" 'new accounts: closed' "$logs"
assert_not_contains "logs never show the owner's e-mail" "$OWNER_EMAIL" "$logs"
assert_not_contains "logs never show the owner's password" 'local-test-only-owner-password' "$logs"
assert_not_contains "logs never show AUTH_SECRET" 'local-test-only-auth-secret' "$logs"

section "prompt library import"
wait_for_log app 'prompt library imported' 1 600 && pass "library import finished" || fail "library import did not finish"
csv_rows=$(docker run --rm --entrypoint node "$IMAGE" -e '
  const t = require("fs").readFileSync("/app/prompts.csv", "utf8"); let rows = 0, q = false;
  for (let i = 0; i < t.length; i++) { const c = t[i]; if (c === "\"") { if (q && t[i+1] === "\"") i++; else q = !q; } else if (c === "\n" && !q) rows++; }
  if (!t.endsWith("\n")) rows++; console.log(rows - 1);')
assert_eq "every CSV prompt is in the database" "$csv_rows" "$(sql 'SELECT count(*) FROM prompts')"
assert_eq "the import is recorded as done" "done" "$(sql "SELECT value FROM railway_template.state WHERE key = 'library_import'")"
assert_eq "imported contributors cannot sign in (no passwords)" "0" "$(sql "SELECT count(*) FROM users WHERE email LIKE '%@unclaimed.prompts.chat' AND password IS NOT NULL")"
res=$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Linux%20Terminal&perPage=5")
assert_contains "anonymous visitors can search the public library" '"title":"Linux Terminal"' "$res"

section "branding and third parties"
home=$(curl -s --max-time 60 "$APP_URL/")
assert_contains "home page carries PCHAT_NAME" 'Railway Test Prompts' "$home"
assert_not_contains "home page has no Sentry" 'sentry' "$home"
assert_not_contains "home page has no Google Analytics" 'googletagmanager' "$home"
assert_contains "page title follows PCHAT_NAME" '<title>Railway Test Prompts</title>' "$home"
assert_not_contains "no prompts.chat title" 'AI Prompts Community' "$home"
if docker run --rm --entrypoint sh "$IMAGE" -c '! grep -rqE "o4510673866063872|9c2eb3b4441745efad28a908001c30bf" /app'; then
  pass "no Sentry DSN anywhere in the built app"
else
  fail "a Sentry DSN is still in the built app"
fi
if docker run --rm --entrypoint sh "$IMAGE" -c '! grep -rq "coderabbit.link" /app/.next'; then pass "no sponsored widgets in the built app"; else fail "sponsored widgets still built in"; fi
assert_eq "sponsored cards are not injected into prompt lists" "0" "$(grep -c 'Try CodeRabbit' <<<"$(curl -s --max-time 60 "$APP_URL/prompts")" || true)"

section "owner sign-in"
printf '%s' wrong-password-for-test > "$TEST_TMP/wrong-pw"
if sign_in "$OWNER_EMAIL" "$TEST_TMP/wrong-pw" "$TEST_TMP/bad.jar"; then fail "a wrong password signed in"; else pass "a wrong password is refused"; fi
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner.jar" && pass "owner signs in with OWNER_PASSWORD" || die "owner sign-in failed"
s=$(session_json "$TEST_TMP/owner.jar")
assert_eq "owner session role" "ADMIN" "$(jq -r '.user.role' <<<"$s")"
assert_eq "owner username" "owner" "$(jq -r '.user.username' <<<"$s")"

section "closed sign-up"
new_password "$TEST_TMP/user-pw"
r=$(register stranger@example.test stranger "$TEST_TMP/user-pw")
assert_eq "e-mail sign-up API refuses" "403" "$(status_of "$r")"
assert_contains "refusal says registration is disabled" 'registration_disabled' "$(body_of "$r")"
code=$(http_code "$APP_URL/register")
[ "$code" != "200" ] && pass "sign-up page is not served ($code)" || fail "sign-up page served while closed"
out=$(sql "INSERT INTO users (id, email, username, \"updatedAt\") VALUES ('oauth-path-test', 'oauth@example.test', 'oauthpath', now())" 2>&1 || true)
assert_contains "the database refuses an OAuth-style account" 'promptschat_signup_not_allowed' "$out"
sql "INSERT INTO users (id, email, username, \"updatedAt\") VALUES ('placeholder-test', 'placeholdertest@unclaimed.prompts.chat', 'placeholdertest', now())" >/dev/null \
  && pass "a password-less contributor placeholder is admitted" || fail "placeholder insert refused"
out=$(sql "UPDATE users SET email = 'claimer@example.test' WHERE id = 'placeholder-test'" 2>&1 || true)
assert_contains "taking over a placeholder with another address is refused" 'promptschat_signup_not_allowed' "$out"
out=$(sql "INSERT INTO users (id, email, username, password, \"updatedAt\") VALUES ('fake-placeholder', 'fake@unclaimed.prompts.chat', 'fakeplaceholder', 'x', now())" 2>&1 || true)
assert_contains "a placeholder address with a password is refused" 'promptschat_signup_not_allowed' "$out"
sql "DELETE FROM users WHERE id = 'placeholder-test'" >/dev/null

section "prompts"
r=$(api POST /api/prompts "$TEST_TMP/owner.jar" '{"title":"Railway private prompt","content":"Act as a careful editor and rewrite the following private notes as three clear bullet points for the Railway smoke test.","type":"TEXT","tagIds":[],"isPrivate":true}')
assert_eq "owner creates a private prompt" "200" "$(status_of "$r")"
private_id=$(jq -r '.id // empty' <<<"$(body_of "$r")")
[ -n "$private_id" ] || die "no prompt id returned"
assert_eq "anonymous visitors cannot read it" "403" "$(http_code "$APP_URL/api/prompts/$private_id")"
assert_eq "the owner can" "200" "$(status_of "$(api GET "/api/prompts/$private_id" "$TEST_TMP/owner.jar")")"
assert_not_contains "it is not in the public list" 'Railway private prompt' "$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Railway%20private")"

section "admin APIs"
assert_eq "admin user list for the owner" "200" "$(status_of "$(api GET /api/admin/users "$TEST_TMP/owner.jar")")"
assert_eq "admin user list for anonymous visitors" "401" "$(http_code "$APP_URL/api/admin/users")"
assert_eq "library import API for anonymous visitors" "401" "$(http_code -X POST "$APP_URL/api/admin/import-prompts")"

section "MCP"
r=$(api POST /api/user/api-key "$TEST_TMP/owner.jar")
assert_eq "owner generates an MCP API key" "200" "$(status_of "$r")"
jq -j '.apiKey' <<<"$(body_of "$r")" > "$TEST_TMP/api-key"; chmod 600 "$TEST_TMP/api-key"
mcp=$(curl -s --max-time 60 -X POST "$APP_URL/api/mcp" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "prompts-api-key: $(cat "$TEST_TMP/api-key")" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_prompts","arguments":{"query":"Linux Terminal"}}}' || true)
assert_contains "MCP search_prompts finds a library prompt" 'Linux Terminal' "$mcp"

section "daily credit reset"
assert_eq "without CRON_SECRET" "401" "$(http_code -X POST "$APP_URL/api/cron/reset-credits")"
assert_eq "with CRON_SECRET" "200" "$(http_code -X POST "$APP_URL/api/cron/reset-credits" -H 'Authorization: Bearer local-test-only-cron-secret')"

section "sign-up allowlist"
restart_app PROMPTSCHAT_TEST_ALLOW_REGISTRATION=true PROMPTSCHAT_TEST_ALLOWED_SIGNUPS='@allowed.test, friend@example.test'
assert_contains "start-up reports the allowlist" 'new accounts: only 2 allowed' "$(compose logs --no-color --since 5m app 2>/dev/null)"
assert_eq "sign-up page is served" "200" "$(http_code "$APP_URL/register")"
r=$(register teammate@allowed.test teammate "$TEST_TMP/user-pw")
assert_eq "an address at an allowed domain signs up" "200" "$(status_of "$r")"
r=$(register friend@example.test friend "$TEST_TMP/user-pw")
assert_eq "an allowed single address signs up" "200" "$(status_of "$r")"
r=$(register intruder@evil.test intruder "$TEST_TMP/user-pw")
assert_eq "any other address is refused" "403" "$(status_of "$r")"
assert_contains "with the policy's reason" 'signup_not_allowed' "$(body_of "$r")"
r=$(register someone@sub.allowed.test subdomain "$TEST_TMP/user-pw")
assert_eq "a subdomain of an allowed domain is refused" "403" "$(status_of "$r")"
r=$(register 'x@evil.test@allowed.test' doubleat "$TEST_TMP/user-pw")
[ "$(status_of "$r")" != "200" ] && pass "a double-@ address is refused ($(status_of "$r"))" || fail "a double-@ address signed up"
out=$(sql "INSERT INTO users (id, email, username, \"updatedAt\") VALUES ('oauth-evil', 'oauth@evil.test', 'oauthevil', now())" 2>&1 || true)
assert_contains "the database refuses an OAuth account outside the list" 'promptschat_signup_not_allowed' "$out"
sql "INSERT INTO users (id, email, username, \"updatedAt\") VALUES ('oauth-ok', 'oauth@allowed.test', 'oauthok', now())" >/dev/null \
  && pass "the database admits an OAuth account on the list" || fail "allowed OAuth-style account refused"
sign_in teammate@allowed.test "$TEST_TMP/user-pw" "$TEST_TMP/team.jar" && pass "the teammate signs in" || fail "teammate sign-in failed"
assert_eq "the teammate is a regular user" "USER" "$(jq -r '.user.role' <<<"$(session_json "$TEST_TMP/team.jar")")"
assert_eq "the teammate cannot read the owner's private prompt" "403" "$(status_of "$(api GET "/api/prompts/$private_id" "$TEST_TMP/team.jar")")"
assert_eq "the teammate cannot use admin APIs" "403" "$(status_of "$(api GET /api/admin/users "$TEST_TMP/team.jar")")"
r=$(api POST /api/prompts "$TEST_TMP/team.jar" '{"title":"Railway team prompt","content":"Act as a friendly teacher and explain the following idea in five short sentences for a new teammate in the Railway smoke test.","type":"TEXT","tagIds":[],"isPrivate":false}')
assert_eq "the teammate publishes a prompt" "200" "$(status_of "$r")"
assert_contains "anonymous visitors see it" 'Railway team prompt' "$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Railway%20team")"

restart_app PROMPTSCHAT_TEST_ALLOW_REGISTRATION=true
assert_contains "open registration without a list warns loudly" 'anyone who can reach this site can create an account' "$(compose logs --no-color --since 2m app 2>/dev/null)"
r=$(register anyone@open.test anyoneopen "$TEST_TMP/user-pw")
assert_eq "open registration admits anyone" "200" "$(status_of "$r")"

restart_app
r=$(register later@allowed.test later "$TEST_TMP/user-pw")
assert_eq "closing again refuses sign-up" "403" "$(status_of "$r")"
sign_in teammate@allowed.test "$TEST_TMP/user-pw" "$TEST_TMP/team.jar" && pass "existing members keep signing in" || fail "existing member locked out"

section "owner password rules"
restart_app PROMPTSCHAT_TEST_OWNER_PASSWORD=changed-local-test-password
printf '%s' changed-local-test-password > "$TEST_TMP/changed-pw"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner.jar" && pass "changing OWNER_PASSWORD alone keeps the first password" || fail "first password stopped working"
if sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/bad.jar"; then fail "the new variable value signed in without a reset"; else pass "the new value does not sign in without a reset"; fi
restart_app PROMPTSCHAT_TEST_OWNER_PASSWORD=changed-local-test-password PROMPTSCHAT_TEST_OWNER_RESET_PASSWORD=true
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/owner.jar" && pass "OWNER_RESET_PASSWORD sets the new password" || fail "reset did not apply"
restart_app
assert_not_contains "the library is imported once, not at every start" 'importing the prompt library' "$(compose logs --no-color app 2>/dev/null)"
assert_eq "the prompt count is unchanged by restarts" "$((csv_rows + 2))" "$(sql 'SELECT count(*) FROM prompts')"

summary
