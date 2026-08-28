#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

banner() { printf '\n========== %s ==========\n' "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

banner "PHP syntax"
if command -v php >/dev/null 2>&1; then
  php -l web/index.php
else
  echo "SKIP: php CLI unavailable; container smoke test performs the runtime PHP check."
fi

banner "bcrypt htpasswd"
if command -v htpasswd >/dev/null 2>&1; then
  tmp_auth="$(mktemp)"
  trap 'rm -f "$tmp_auth"' EXIT
  htpasswd -Bbn test-user 'test-password-only' > "$tmp_auth"
  grep -Eq '^test-user:\$2[aby]\$' "$tmp_auth" || fail "htpasswd output is not bcrypt"
  htpasswd -vb "$tmp_auth" test-user 'test-password-only'
  if htpasswd -vb "$tmp_auth" test-user 'wrong-password' >/dev/null 2>&1; then
    fail "wrong htpasswd password unexpectedly verified"
  fi
  echo "PASS: bcrypt creation and verification"
else
  echo "SKIP: htpasswd unavailable; it is installed in the container image."
fi

banner "Rendered backup management dashboard"
if command -v php >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" ${tmp_auth:-}' EXIT
  mkdir -p "$tmp/storage/books.backup" "$tmp/storage/evil<script>.backup" "$tmp/storage/.webui-auth" "$tmp/runtime"
  printf 'backup-data' > "$tmp/storage/books.backup/data.zip"
  printf 'evil-data' > "$tmp/storage/evil<script>.backup/data.zip"
  printf 'test-csrf-secret' > "$tmp/storage/.webui-auth/password"
  chmod 600 "$tmp/storage/.webui-auth/password"
  now="$(date +%s)"
  cat > "$tmp/runtime/uploads.json" <<JSON
{"uploads":{"test":{"backup_name":"sync.backup","filename":"<img src=x onerror=alert(1)>.zip","bytes_received":512,"total_bytes":1024,"started_at":$now,"updated_at":$now}}}
JSON
  LNREADER_STORAGE_DIR="$tmp/storage" \
  LNREADER_RUNTIME_DIR="$tmp/runtime" \
  PUBLIC_URL="https://lnreader.example.test" \
  WEB_UI_SLUG="lnr-vault-7f3c9" \
    php web/index.php > "$tmp/dashboard.html"
  grep -Fq 'https://lnreader.example.test' "$tmp/dashboard.html" || fail "PUBLIC_URL missing from dashboard"
  grep -Fq 'books.backup' "$tmp/dashboard.html" || fail "stored backup missing from dashboard"
  grep -Fq 'sync.backup' "$tmp/dashboard.html" || fail "active upload missing from dashboard"
  grep -Fq 'evil&lt;script&gt;.backup' "$tmp/dashboard.html" || fail "backup name was not HTML-escaped"
  grep -Fq '&lt;img src=x onerror=alert(1)&gt;.zip' "$tmp/dashboard.html" || fail "active filename was not HTML-escaped"
  if grep -Fq 'evil<script>.backup' "$tmp/dashboard.html" || grep -Fq '<img src=x onerror=alert(1)>.zip' "$tmp/dashboard.html"; then
    fail "unescaped attacker-controlled text reached dashboard HTML"
  fi
  grep -Fq 'Authenticated backup management console' "$tmp/dashboard.html" || fail "dashboard marker missing"
  if grep -Eiq '<script|javascript:' "$tmp/dashboard.html"; then
    fail "dashboard unexpectedly contains JavaScript"
  fi

  grep -Fq 'class="danger-button"' "$tmp/dashboard.html" ||
    fail "stored backup delete button missing"

  grep -Fq 'value="confirm"' "$tmp/dashboard.html" ||
    fail "stored backup confirmation action missing"

  token="$(
    php -r \
      "echo hash_hmac('sha256', 'delete-backup:books.backup', 'test-csrf-secret');"
  )"

  TEST_CSRF="$token" \
  LNREADER_STORAGE_DIR="$tmp/storage" \
  LNREADER_RUNTIME_DIR="$tmp/runtime" \
  PUBLIC_URL="https://lnreader.example.test" \
  WEB_UI_SLUG="lnr-vault-7f3c9" \
    php -r '
      $_SERVER["REQUEST_METHOD"] = "POST";
      $_POST = [
          "action" => "confirm",
          "backup" => "books.backup",
          "csrf" => (string)getenv("TEST_CSRF"),
      ];
      include "web/index.php";
    ' > "$tmp/delete-confirm.html"

  grep -Fq 'Delete permanently' "$tmp/delete-confirm.html" ||
    fail "delete confirmation page missing"

  [[ -d "$tmp/storage/books.backup" ]] ||
    fail "confirmation unexpectedly deleted backup"

  TEST_CSRF="$token" \
  LNREADER_STORAGE_DIR="$tmp/storage" \
  LNREADER_RUNTIME_DIR="$tmp/runtime" \
  PUBLIC_URL="https://lnreader.example.test" \
  WEB_UI_SLUG="lnr-vault-7f3c9" \
    php -r '
      $_SERVER["REQUEST_METHOD"] = "POST";
      $_POST = [
          "action" => "delete",
          "backup" => "books.backup",
          "csrf" => (string)getenv("TEST_CSRF"),
      ];
      include "web/index.php";
    ' > /dev/null

  [[ ! -e "$tmp/storage/books.backup" ]] ||
    fail "confirmed deletion did not remove selected backup"

  echo "PASS: dashboard confirms and deletes only the selected backup"

  # A backup with an active upload must not be removable.
  mkdir -p "$tmp/storage/active.backup"
  printf 'keep-me' > "$tmp/storage/active.backup/data.zip"

  now="$(date +%s)"

  cat > "$tmp/runtime/uploads.json" <<JSON
{"uploads":{"delete-test":{"backup_name":"active.backup","filename":"data.zip","bytes_received":10,"total_bytes":100,"started_at":$now,"updated_at":$now}}}
JSON

  active_token="$(
    php -r \
      "echo hash_hmac('sha256', 'delete-backup:active.backup', 'test-csrf-secret');"
  )"

  TEST_CSRF="$active_token" \
  LNREADER_STORAGE_DIR="$tmp/storage" \
  LNREADER_RUNTIME_DIR="$tmp/runtime" \
  PUBLIC_URL="https://lnreader.example.test" \
  WEB_UI_SLUG="lnr-vault-7f3c9" \
    php -r '
      $_SERVER["REQUEST_METHOD"] = "POST";
      $_POST = [
          "action" => "delete",
          "backup" => "active.backup",
          "csrf" => (string)getenv("TEST_CSRF"),
      ];
      include "web/index.php";
    ' > "$tmp/delete-active.html"

  grep -Fq 'active upload' "$tmp/delete-active.html" ||
    fail "active-upload deletion was not rejected"

  [[ -d "$tmp/storage/active.backup" ]] ||
    fail "active backup was deleted"

  echo "PASS: active backup deletion is blocked"


  echo "PASS: dashboard renders public URL, backups and active uploads without JavaScript"
else
  echo "SKIP: PHP rendering unavailable."
fi

banner "Nginx security template"
for token in \
  'auth_basic' \
  'auth_basic_user_file' \
  'Content-Security-Policy' \
  'X-Robots-Tag' \
  'limit_req zone=lnreader_ui_auth' \
  'limit_except GET POST' \
  'proxy_request_buffering off'; do
  grep -Fq "$token" docker/nginx.conf.template || fail "missing nginx token: $token"
  echo "PASS: $token"
done

echo "PASS: web UI validation complete"

banner "Automatic Web UI credential lifecycle"
./scripts/webui-auth-test.sh
