#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cond && pass || fail` is intentional; pass/fail always succeed
# Shared helpers for promptschat-railway tests. Source this file; do not execute it.
# Secrets are never echoed. Only names, counts, and pass/fail results are printed.

: "${APP_URL:=http://localhost:${PROMPTSCHAT_TEST_PORT:-13700}}"
: "${TEST_TIMEOUT:=900}"

TEST_TMP="${TEST_TMP:-$(mktemp -d)}"
export TEST_TMP
_PASS=0; _FAIL=0

pass() { _PASS=$((_PASS+1)); printf '  PASS  %s\n' "$*"; }
fail() { _FAIL=$((_FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
summary() { printf '\n%d passed, %d failed\n' "$_PASS" "$_FAIL"; [ "$_FAIL" -eq 0 ]; }

# here-strings, not pipes: `grep -q` exits on the first match and a pipe writer would get SIGPIPE,
# which `pipefail` reports as failure when the haystack is larger than the pipe buffer
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1: expected [$2] got [$3]"; fi; }
assert_contains() { if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1: missing [$2]"; fi; }
assert_not_contains() { if grep -q -- "$2" <<<"$3"; then fail "$1: found forbidden [$2]"; else pass "$1"; fi; }

# curl still prints 000 through -w when it cannot connect, so `|| true`, never `|| echo 000`
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$@" || true; }

wait_for_code() {
  local url=$1 want=$2 timeout=${3:-$TEST_TIMEOUT} start code
  start=$(date +%s)
  while :; do
    code=$(http_code "$url")
    [ "$code" = "$want" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for %s -> %s (last %s)\n' "$url" "$want" "$code" >&2; return 1; fi
    sleep 5
  done
}

compose() { docker compose -f "$REPO_ROOT/compose.yaml" "$@"; }

# wait_for_log SERVICE PATTERN [MIN_COUNT] [TIMEOUT]
wait_for_log() {
  local svc=$1 pat=$2 min=${3:-1} timeout=${4:-$TEST_TIMEOUT} start n
  start=$(date +%s)
  while :; do
    n=$(compose logs --no-color --no-log-prefix "$svc" 2>/dev/null | grep -cE -- "$pat" || true)
    [ "$n" -ge "$min" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for [%s] in %s logs\n' "$pat" "$svc" >&2; return 1; fi
    sleep 3
  done
}

# psql against the test database; prints unaligned tuples only
sql() { compose exec -T db psql -U prompts -d prompts -Atq -v ON_ERROR_STOP=1 -c "$1"; }

# sign_in EMAIL PASSWORD_FILE JAR -> 0 when Auth.js issued a session cookie into JAR. The password file must not
# end in a newline: curl sends the file's bytes as they are.
# The same two requests the login form makes: a CSRF token, then the credentials callback.
sign_in() {
  local email=$1 pwfile=$2 jar=$3 csrf
  rm -f "$jar"
  csrf=$(curl -s --max-time 30 -c "$jar" -b "$jar" "$APP_URL/api/auth/csrf" | jq -r '.csrfToken // empty' || true)
  [ -n "$csrf" ] || return 1
  curl -s -o /dev/null --max-time 60 -c "$jar" -b "$jar" -X POST "$APP_URL/api/auth/callback/credentials" \
    --data-urlencode "email=$email" --data-urlencode "password@$pwfile" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=$APP_URL/" || return 1
  grep -q 'session-token' "$jar"
}

# session_json JAR -> the Auth.js session as JSON ({} when signed out)
session_json() { curl -s --max-time 30 -b "$1" "$APP_URL/api/auth/session" || true; }

# api METHOD PATH JAR [JSON_BODY] -> prints "<body>\n<status>"
api() {
  local method=$1 path=$2 jar=$3 body=${4:-}
  if [ -n "$body" ]; then
    curl -s -w '\n%{http_code}' --max-time 120 -b "$jar" -X "$method" "$APP_URL$path" -H 'Content-Type: application/json' --data "$body" || true
  else
    curl -s -w '\n%{http_code}' --max-time 120 -b "$jar" -X "$method" "$APP_URL$path" || true
  fi
}
status_of() { printf '%s' "${1##*$'\n'}"; }
body_of() { printf '%s' "${1%$'\n'*}"; }

# register EMAIL USERNAME PASSWORD_FILE -> prints "<body>\n<status>" of the e-mail sign-up API
register() {
  local data
  data=$(jq -nc --arg e "$1" --arg u "$2" --rawfile p "$3" '{name:"Test User", username:$u, email:$e, password:($p|rtrimstr("\n"))}')
  curl -s -w '\n%{http_code}' --max-time 60 -X POST "$APP_URL/api/auth/register" -H 'Content-Type: application/json' --data "$data" || true
}

# new_password FILE -> writes a random password to FILE (mode 600)
new_password() { (umask 077; openssl rand -hex 16 | tr -d '\n' > "$1"); }
