#!/usr/bin/env bash
# shellcheck disable=SC2015
# Live test of a deployed template: every product flow the local smoke test covers that can be reached over HTTPS.
#
#   OWNER_EMAIL=you@example.com OWNER_PASSWORD_FILE=./owner-password tests/railway-smoke.sh https://<app-domain>
#
# Optional:
#   PROMPTSCHAT_SMOKE_PHASE=allowlist  the deployment runs with PCHAT_ALLOW_REGISTRATION=true and
#                                      PROMPTS_ALLOWED_SIGNUPS containing @$ALLOWED_DOMAIN: tests member sign-up
#   ALLOWED_DOMAIN                     the allowed domain for that phase (default railway-smoke.test)
#   CRON_SECRET_FILE                   a file holding CRON_SECRET, to check the credit reset endpoint accepts it
# Rerunnable: every account and prompt it creates has a unique name and content (upstream refuses near-duplicates). Secrets are read from files, never printed.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
[ $# -ge 1 ] || { sed -n '3,13p' "$0"; exit 2; }
APP_URL=${1%/}; export APP_URL
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
trap 'rm -rf "$TEST_TMP"' EXIT

: "${OWNER_EMAIL:?set OWNER_EMAIL}"
: "${OWNER_PASSWORD_FILE:?set OWNER_PASSWORD_FILE}"
PHASE=${PROMPTSCHAT_SMOKE_PHASE:-closed}
ALLOWED_DOMAIN=${ALLOWED_DOMAIN:-railway-smoke.test}
RUN=$(date +%s)$RANDOM
tr -d '\n' < "$OWNER_PASSWORD_FILE" > "$TEST_TMP/owner-pw"; chmod 600 "$TEST_TMP/owner-pw"

section "availability"
wait_for_code "$APP_URL/api/health" 200 900 && pass "health endpoint answers 200 over HTTPS" || die "not healthy"
home=$(curl -s --max-time 60 "$APP_URL/")
assert_contains "home page renders the library" '<html' "$home"
assert_not_contains "no Sentry on the page" 'sentry' "$home"
assert_not_contains "no Google Analytics on the page" 'googletagmanager' "$home"
assert_not_contains "no prompts.chat sponsors on the home page" 'coderabbit' "$home"

section "prompt library"
start=$(date +%s); found=""
while [ $(( $(date +%s) - start )) -lt 900 ]; do
  found=$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Linux%20Terminal&perPage=5" || true)
  grep -q '"title":"Linux Terminal"' <<<"$found" && break
  sleep 10
done
assert_contains "the imported library is searchable anonymously" '"title":"Linux Terminal"' "$found"
total=$(curl -s --max-time 60 "$APP_URL/api/prompts?perPage=1" | jq -r '.total // 0')
[ "$total" -ge 2000 ] && pass "public library holds $total prompts" || fail "public library holds only $total prompts"

section "owner"
printf '%s' "wrong-$RUN" > "$TEST_TMP/wrong-pw"
if sign_in "$OWNER_EMAIL" "$TEST_TMP/wrong-pw" "$TEST_TMP/bad.jar"; then fail "a wrong password signed in"; else pass "a wrong password is refused"; fi
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner.jar" && pass "owner signs in with OWNER_PASSWORD" || die "owner sign-in failed"
assert_eq "owner is ADMIN" "ADMIN" "$(jq -r '.user.role' <<<"$(session_json "$TEST_TMP/owner.jar")")"
assert_contains "the session cookie is Secure over HTTPS" '__Secure-authjs.session-token' "$(cat "$TEST_TMP/owner.jar")"

section "prompts"
r=$(api POST /api/prompts "$TEST_TMP/owner.jar" "$(jq -nc --arg t "Railway live private $RUN" '{title:$t, content:("Act as a careful editor and rewrite the following private notes as three clear bullet points, run " + $t), type:"TEXT", tagIds:[], isPrivate:true}')")
assert_eq "owner creates a private prompt" "200" "$(status_of "$r")"
private_id=$(jq -r '.id // empty' <<<"$(body_of "$r")")
[ -n "$private_id" ] || die "no prompt id returned"
assert_eq "anonymous visitors cannot read it" "403" "$(http_code "$APP_URL/api/prompts/$private_id")"
assert_eq "the owner can" "200" "$(status_of "$(api GET "/api/prompts/$private_id" "$TEST_TMP/owner.jar")")"
assert_not_contains "it is not in the public list" "Railway live private $RUN" "$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Railway%20live%20private")"

section "admin"
assert_eq "admin API for the owner" "200" "$(status_of "$(api GET /api/admin/users "$TEST_TMP/owner.jar")")"
assert_eq "admin API for anonymous visitors" "401" "$(http_code "$APP_URL/api/admin/users")"
assert_eq "library import API for anonymous visitors" "401" "$(http_code -X POST "$APP_URL/api/admin/import-prompts")"
assert_eq "credit reset without CRON_SECRET" "401" "$(http_code -X POST "$APP_URL/api/cron/reset-credits")"
if [ -n "${CRON_SECRET_FILE:-}" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$APP_URL/api/cron/reset-credits" -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '\n' < "$CRON_SECRET_FILE")") || true)
  assert_eq "credit reset with CRON_SECRET" "200" "$code"
fi

section "MCP"
r=$(api POST /api/user/api-key "$TEST_TMP/owner.jar")
assert_eq "owner generates an MCP API key" "200" "$(status_of "$r")"
jq -j '.apiKey' <<<"$(body_of "$r")" > "$TEST_TMP/api-key"; chmod 600 "$TEST_TMP/api-key"
mcp=$(curl -s --max-time 60 -X POST "$APP_URL/api/mcp" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H @<(printf 'prompts-api-key: %s\n' "$(cat "$TEST_TMP/api-key")") \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_prompts","arguments":{"query":"Linux Terminal"}}}' || true)
assert_contains "MCP search_prompts over HTTPS finds a library prompt" 'Linux Terminal' "$mcp"

new_password "$TEST_TMP/user-pw"
if [ "$PHASE" = closed ]; then
  section "closed sign-up"
  r=$(register "stranger$RUN@$ALLOWED_DOMAIN" "stranger$RUN" "$TEST_TMP/user-pw")
  assert_eq "e-mail sign-up API refuses, even for the test domain" "403" "$(status_of "$r")"
  code=$(http_code "$APP_URL/register")
  [ "$code" != "200" ] && pass "sign-up page is not served ($code)" || fail "sign-up page served while closed"
else
  section "allowlisted sign-up"
  assert_eq "sign-up page is served" "200" "$(http_code "$APP_URL/register")"
  member="member$RUN@$ALLOWED_DOMAIN"
  r=$(register "$member" "member$RUN" "$TEST_TMP/user-pw")
  assert_eq "an address at the allowed domain signs up" "200" "$(status_of "$r")"
  r=$(register "intruder$RUN@example.com" "intruder$RUN" "$TEST_TMP/user-pw")
  assert_eq "any other address is refused" "403" "$(status_of "$r")"
  assert_contains "with the policy's reason" 'signup_not_allowed' "$(body_of "$r")"
  r=$(register "sub$RUN@x.$ALLOWED_DOMAIN" "sub$RUN" "$TEST_TMP/user-pw")
  assert_eq "a subdomain is refused" "403" "$(status_of "$r")"
  sign_in "$member" "$TEST_TMP/user-pw" "$TEST_TMP/member.jar" && pass "the member signs in" || fail "member sign-in failed"
  assert_eq "the member is a regular user" "USER" "$(jq -r '.user.role' <<<"$(session_json "$TEST_TMP/member.jar")")"
  assert_eq "the member cannot read the owner's private prompt" "403" "$(status_of "$(api GET "/api/prompts/$private_id" "$TEST_TMP/member.jar")")"
  assert_eq "the member cannot use admin APIs" "403" "$(status_of "$(api GET /api/admin/users "$TEST_TMP/member.jar")")"
  r=$(api POST /api/prompts "$TEST_TMP/member.jar" "$(jq -nc --arg t "Railway live shared $RUN" '{title:$t, content:("Act as a friendly teacher and explain the following idea in five short sentences for a new teammate: " + $t), type:"TEXT", tagIds:[], isPrivate:false}')")
  assert_eq "the member publishes a prompt" "200" "$(status_of "$r")"
  assert_contains "anonymous visitors see it" "Railway live shared $RUN" "$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Railway%20live%20shared%20$RUN")"
fi

summary
