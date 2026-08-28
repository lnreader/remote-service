#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v htpasswd >/dev/null 2>&1 || { echo 'SKIP: htpasswd unavailable'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: python3 unavailable'; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/storage" "$TMP/runtime"

run_auth() {
  LNREADER_STORAGE_DIR="$TMP/storage" \
  LNREADER_RUNTIME_DIR="$TMP/runtime" \
  WEB_UI_SLUG="lnr-vault-7f3c9" \
  WEB_UI_USERNAME="${WEB_UI_USERNAME:-admin}" \
  WEB_UI_PASSWORD="${WEB_UI_PASSWORD:-}" \
    sh docker/init-webui-auth.sh
}

echo '=== automatic credential generation ==='
unset WEB_UI_PASSWORD WEB_UI_USERNAME || true
output="$(run_auth)"
user="$(cat "$TMP/storage/.webui-auth/username")"
pass="$(cat "$TMP/storage/.webui-auth/password")"
[[ "$user" == admin ]] || fail "default username is not admin"
[[ ${#pass} -ge 30 ]] || fail "generated password is unexpectedly short"
grep -Fq "Password: $pass" <<<"$output" || fail "generated password was not printed on first start"
htpasswd -vb "$TMP/runtime/.htpasswd" "$user" "$pass" >/dev/null || fail "generated bcrypt credential did not verify"
chmod_mode="$(stat -c '%a' "$TMP/storage/.webui-auth/password")"
[[ "$chmod_mode" == 600 ]] || fail "password file mode is $chmod_mode, expected 600"
echo 'PASS: random admin password generated, persisted, printed, and bcrypt-verified'

echo '=== credential persistence ==='
rm -rf "$TMP/runtime"
mkdir -p "$TMP/runtime"
output2="$(run_auth)"
pass2="$(cat "$TMP/storage/.webui-auth/password")"
[[ "$pass2" == "$pass" ]] || fail "password changed between starts"
if grep -Fq "Password: $pass" <<<"$output2"; then
  fail "persisted password was printed again on restart"
fi
htpasswd -vb "$TMP/runtime/.htpasswd" admin "$pass2" >/dev/null || fail "persisted credential did not verify"
echo 'PASS: password survives recreation and is not reprinted'

echo '=== .env-style override ==='
rm -rf "$TMP/runtime"
mkdir -p "$TMP/runtime"
WEB_UI_USERNAME='smoke-admin' WEB_UI_PASSWORD='custom-test-password-123456789' run_auth >/dev/null
[[ "$(cat "$TMP/storage/.webui-auth/username")" == 'smoke-admin' ]] || fail "custom username was not persisted"
[[ "$(cat "$TMP/storage/.webui-auth/password")" == 'custom-test-password-123456789' ]] || fail "custom password was not persisted"
htpasswd -vb "$TMP/runtime/.htpasswd" smoke-admin 'custom-test-password-123456789' >/dev/null || fail "custom bcrypt credential did not verify"
echo 'PASS: WEB_UI_USERNAME/WEB_UI_PASSWORD override persisted credentials'

echo '=== invalid username ==='
if WEB_UI_USERNAME='bad:user' WEB_UI_PASSWORD='a-long-test-password' run_auth >/dev/null 2>&1; then
  fail "invalid username unexpectedly accepted"
fi
echo 'PASS: invalid username rejected'
