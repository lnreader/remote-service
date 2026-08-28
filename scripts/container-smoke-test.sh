#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-lnreader-remote-service:test}"
NAME="lnreader-smoke-$RANDOM"
TMP="$(mktemp -d)"
PORT="${SMOKE_PORT:-18000}"
SLUG="lnr-vault-7f3c9"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

banner() { printf '\n\n========== %s ==========\n' "$1"; }
fail() {
  echo "FAIL: $*" >&2
  echo
  echo "===== docker logs ====="
  docker logs "$NAME" 2>&1 || true
  echo
  echo "===== runtime service logs ====="
  docker exec "$NAME" sh -c '
    for f in /run/lnreader/*.log; do
      [ -f "$f" ] || continue
      echo
      echo "----- $f -----"
      tail -n 200 "$f"
    done
  ' 2>&1 || true
  exit 1
}

wait_healthy() {
  for i in {1..60}; do
    if curl --fail --silent --show-error "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      echo "PASS: service healthy after $i polls"
      return 0
    fi
    sleep 1
  done
  fail "healthz never became ready"
}

start_generated() {
  docker run -d \
    --name "$NAME" \
    --security-opt no-new-privileges:true \
    -p "$PORT:8000" \
    -e PUBLIC_URL="https://lnreader.example.test" \
    -e WEB_UI_SLUG="$SLUG" \
    -v "$TMP/storage:/home/lnreader/.LNReader" \
    "$IMAGE"
}

mkdir -p "$TMP/storage"
banner "Start with automatic Web UI credentials"
start_generated
wait_healthy

AUTH_USER="$(cat "$TMP/storage/.webui-auth/username")"
AUTH_PASS="$(cat "$TMP/storage/.webui-auth/password")"
[[ "$AUTH_USER" == admin ]] || fail "generated username expected admin, got $AUTH_USER"
[[ ${#AUTH_PASS} -ge 30 ]] || fail "generated password is unexpectedly short"
docker logs "$NAME" 2>&1 | grep -Fq "Password: $AUTH_PASS" || fail "first-start password was not shown in docker logs"
echo "PASS: generated admin credential is persisted and printed on first start"

banner "Container health and configuration"
docker inspect --format='Health={{json .State.Health}}' "$NAME"
docker exec "$NAME" nginx -t
docker exec "$NAME" sh -c 'printf "PID1 "; grep "^Uid:" /proc/1/status'
docker exec "$NAME" sh -c 'uid=$(sed -n "s/^Uid:[[:space:]]*\([0-9][0-9]*\).*/\1/p" /proc/1/status); [ "$uid" -ne 0 ]'
echo "PASS: PID 1 is not root"

banner "API compatibility"
curl --fail --silent --show-error "http://127.0.0.1:$PORT/" | tee "$TMP/root.json"
grep -Fq 'LNReader' "$TMP/root.json" || fail "root API response changed"
printf 'smoke-payload' > "$TMP/payload.bin"
curl --fail --silent --show-error --data-binary @"$TMP/payload.bin" \
  "http://127.0.0.1:$PORT/upload/smoke.backup&&data.bin" | tee "$TMP/upload.json"
curl --fail --silent --show-error "http://127.0.0.1:$PORT/list" | tee "$TMP/list.json"
grep -Fq 'smoke.backup' "$TMP/list.json" || fail "backup absent from /list"
curl --fail --silent --show-error "http://127.0.0.1:$PORT/download/smoke.backup&&data.bin" > "$TMP/download.bin"
cmp "$TMP/payload.bin" "$TMP/download.bin"
echo "PASS: upload/list/download round trip"

banner "Chunked streaming upload"

dd if=/dev/urandom of="$TMP/chunked.bin" bs=1M count=8 status=none

curl --http1.1   --fail   --silent   --show-error   -H 'Content-Length:'   -H 'Transfer-Encoding: chunked'   --data-binary @"$TMP/chunked.bin"   "http://127.0.0.1:$PORT/upload/chunked.backup&&data.bin"   > "$TMP/chunked-upload.json"

curl   --fail   --silent   --show-error   "http://127.0.0.1:$PORT/download/chunked.backup&&data.bin"   > "$TMP/chunked-download.bin"

cmp "$TMP/chunked.bin" "$TMP/chunked-download.bin"

grep -Fq '"size":8388608' "$TMP/chunked-upload.json" ||
  fail "chunked upload returned unexpected size"

echo "PASS: chunked request streamed and round-tripped without Content-Length"

banner "Live chunked request streaming"

dd if=/dev/zero of="$TMP/live-chunked.bin" bs=1M count=2 status=none

curl --http1.1   --fail   --silent   --show-error   --limit-rate 256k   -H 'Content-Length:'   -H 'Transfer-Encoding: chunked'   --data-binary @"$TMP/live-chunked.bin"   "http://127.0.0.1:$PORT/upload/live-chunked.backup&&slow.bin"   > "$TMP/live-chunked-upload.json" &

chunked_pid=$!

visible=0

for _ in $(seq 1 20); do
  if docker exec "$NAME" sh -c     'grep -Fq "live-chunked.backup" /run/lnreader/uploads.json 2>/dev/null'
  then
    visible=1
    break
  fi

  sleep 0.25
done

if [[ "$visible" != 1 ]]; then
  kill "$chunked_pid" 2>/dev/null || true
  wait "$chunked_pid" 2>/dev/null || true
  fail "Gunicorn did not see chunked upload before client completed"
fi

echo "PASS: chunked body reaches Gunicorn before upload completes"

wait "$chunked_pid"

curl   --fail   --silent   --show-error   "http://127.0.0.1:$PORT/download/live-chunked.backup&&slow.bin"   > "$TMP/live-chunked-download.bin"

cmp "$TMP/live-chunked.bin" "$TMP/live-chunked-download.bin"

echo "PASS: live chunked upload completed and round-tripped"

banner "Reverse proxy scheme normalization"

proxy_response="$(
  curl --fail --silent --show-error \
    -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Ssl: on' \
    -H 'X-Forwarded-Protocol: ssl' \
    "http://127.0.0.1:$PORT/healthz"
)"

[[ "$proxy_response" == '{"status":"ok"}' ]] ||
  fail "conflicting reverse-proxy scheme headers were not normalized: $proxy_response"

echo "PASS: conflicting reverse-proxy scheme headers are normalized"

banner "Web UI authentication"
status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/$SLUG/")"
[[ "$status" == 401 ]] || fail "unauthenticated dashboard expected 401, got $status"
status="$(curl -sS -u "$AUTH_USER:wrong-password" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/$SLUG/")"
[[ "$status" == 401 ]] || fail "wrong password expected 401, got $status"
curl --fail --silent --show-error -u "$AUTH_USER:$AUTH_PASS" \
  -D "$TMP/headers.txt" "http://127.0.0.1:$PORT/$SLUG/" > "$TMP/dashboard.html"
grep -Fq 'https://lnreader.example.test' "$TMP/dashboard.html" || fail "public app URL not shown"
grep -Fqi 'Content-Security-Policy:' "$TMP/headers.txt" || fail "CSP header missing"
grep -Fqi 'Cache-Control: no-store' "$TMP/headers.txt" || fail "no-store header missing"
grep -Fqi 'X-Robots-Tag:' "$TMP/headers.txt" || fail "robots header missing"
echo "PASS: generated credential protects dashboard"

banner "Current upload visibility"
dd if=/dev/zero of="$TMP/slow.bin" bs=1M count=4 status=none
curl --silent --show-error --limit-rate 128k --data-binary @"$TMP/slow.bin" \
  "http://127.0.0.1:$PORT/upload/live.backup&&slow.bin" > "$TMP/slow-upload.json" &
upload_pid=$!
visible=0
for i in {1..30}; do
  curl --fail --silent --show-error -u "$AUTH_USER:$AUTH_PASS" \
    "http://127.0.0.1:$PORT/$SLUG/" > "$TMP/live-dashboard.html"
  if grep -Fq 'live.backup' "$TMP/live-dashboard.html" && grep -Fq 'slow.bin' "$TMP/live-dashboard.html"; then
    visible=1
    echo "PASS: running upload visible on dashboard after $i polls"
    break
  fi
  sleep 0.5
done
[[ "$visible" == 1 ]] || fail "running upload never appeared in dashboard"
wait "$upload_pid"

banner "Generated credential persistence"
ORIGINAL_PASS="$AUTH_PASS"
docker rm -f "$NAME" >/dev/null
start_generated >/dev/null
wait_healthy
AUTH_PASS="$(cat "$TMP/storage/.webui-auth/password")"
[[ "$AUTH_PASS" == "$ORIGINAL_PASS" ]] || fail "generated password changed after recreation"
if docker logs "$NAME" 2>&1 | grep -Fq "Password: $AUTH_PASS"; then
  fail "persisted password was printed again during recreation"
fi
curl --fail --silent --show-error -u "admin:$AUTH_PASS" "http://127.0.0.1:$PORT/$SLUG/" >/dev/null
echo "PASS: generated credential survives container recreation"

banner ".env-style credential override"
docker rm -f "$NAME" >/dev/null
docker run -d \
  --name "$NAME" \
  --security-opt no-new-privileges:true \
  -p "$PORT:8000" \
  -e PUBLIC_URL="https://lnreader.example.test" \
  -e WEB_UI_SLUG="$SLUG" \
  -e WEB_UI_USERNAME="smoke-admin" \
  -e WEB_UI_PASSWORD="verbose-test-password-123456" \
  -v "$TMP/storage:/home/lnreader/.LNReader" \
  "$IMAGE" >/dev/null
wait_healthy
curl --fail --silent --show-error -u 'smoke-admin:verbose-test-password-123456' \
  "http://127.0.0.1:$PORT/$SLUG/" >/dev/null
[[ "$(cat "$TMP/storage/.webui-auth/username")" == 'smoke-admin' ]] || fail "custom username not persisted"
[[ "$(cat "$TMP/storage/.webui-auth/password")" == 'verbose-test-password-123456' ]] || fail "custom password not persisted"
echo "PASS: WEB_UI_USERNAME/WEB_UI_PASSWORD replace generated credentials"

banner "Success"
echo "All container/UI smoke checks passed."
