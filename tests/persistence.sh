#!/usr/bin/env bash
# shellcheck disable=SC2015
# Persistence: everything lives in PostgreSQL. Take the whole stack down (keeping volumes), bring it back, and check
# the owner, members, prompts, the library, the sign-up gate and the import marker all survived. Run after smoke.sh.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
trap 'rm -rf "$TEST_TMP"' EXIT

OWNER_EMAIL=owner@example.test
# smoke.sh ends with the owner's password reset to this value.
printf '%s' changed-local-test-password > "$TEST_TMP/owner-pw"

wait_for_code "$APP_URL/api/health" 200 60 || die "the stack is not running; run tests/smoke.sh first"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/before.jar" || die "owner sign-in failed before the restart"

section "before"
prompts_before=$(sql 'SELECT count(*) FROM prompts')
users_before=$(sql 'SELECT count(*) FROM users')
private_id=$(sql "SELECT id FROM prompts WHERE title = 'Railway private prompt'")
[ -n "$private_id" ] || die "smoke.sh's private prompt is missing"
pass "recorded $prompts_before prompts and $users_before users"

section "full restart"
compose down >/dev/null 2>&1
compose up -d >/dev/null 2>&1 || die "compose up failed"
wait_for_code "$APP_URL/api/health" 200 600 && pass "healthy again" || die "not healthy after the restart"
wait_for_log app 'listening on port' 1 300 >/dev/null || true

section "after"
assert_eq "prompt count" "$prompts_before" "$(sql 'SELECT count(*) FROM prompts')"
assert_eq "user count" "$users_before" "$(sql 'SELECT count(*) FROM users')"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner.jar" && pass "owner signs in with the same password" || fail "owner sign-in failed"
assert_eq "owner is still ADMIN" "ADMIN" "$(jq -r '.user.role' <<<"$(session_json "$TEST_TMP/owner.jar")")"
assert_eq "the session issued before the restart is still valid" "owner" "$(jq -r '.user.username // empty' <<<"$(session_json "$TEST_TMP/before.jar")")"
assert_eq "the private prompt is still private" "403" "$(http_code "$APP_URL/api/prompts/$private_id")"
assert_eq "and still the owner's" "200" "$(status_of "$(api GET "/api/prompts/$private_id" "$TEST_TMP/owner.jar")")"
assert_contains "the library is still searchable" '"title":"Linux Terminal"' "$(curl -s --max-time 60 "$APP_URL/api/prompts?q=Linux%20Terminal&perPage=5")"
assert_eq "the import marker survived" "done" "$(sql "SELECT value FROM railway_template.state WHERE key = 'library_import'")"
assert_not_contains "no second import" 'importing the prompt library' "$(compose logs --no-color app 2>/dev/null)"
assert_eq "the sign-up gate is still installed" "railway_template_gate" "$(sql "SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.users'::regclass AND NOT tgisinternal")"
new_password "$TEST_TMP/user-pw"
assert_eq "sign-up is still closed" "403" "$(status_of "$(register after@example.test afterrestart "$TEST_TMP/user-pw")")"
assert_eq "the teammate is still a regular user" "USER" "$(sql "SELECT role FROM users WHERE email = 'teammate@allowed.test'")"

summary
