#!/bin/sh
set -eu

STORAGE_DIR="${LNREADER_STORAGE_DIR:-/home/lnreader/.LNReader}"
RUNTIME_DIR="${LNREADER_RUNTIME_DIR:-/run/lnreader}"
FIX_PERMISSIONS="${FIX_PERMISSIONS:-true}"
WEB_UI_SLUG="${WEB_UI_SLUG:-lnr-vault-7f3c9}"
PORT="${PORT:-8000}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-20g}"
PUBLIC_URL="${PUBLIC_URL:-}"
PUID="${PUID:-}"
PGID="${PGID:-}"

case "$PORT" in
  *[!0-9]*|'') echo "ERROR: PORT must be numeric" >&2; exit 64 ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: PORT must be between 1 and 65535" >&2
  exit 64
fi

case "$WEB_UI_SLUG" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: WEB_UI_SLUG may contain only letters, digits, dot, underscore and dash" >&2
    exit 64
    ;;
esac

if ! printf '%s' "$MAX_UPLOAD_SIZE" | grep -Eq '^[0-9]+[kKmMgG]?$'; then
  echo "ERROR: MAX_UPLOAD_SIZE must look like 512m, 2g, etc." >&2
  exit 64
fi

mkdir -p "$STORAGE_DIR" "$RUNTIME_DIR" \
  "$RUNTIME_DIR/client_temp" \
  "$RUNTIME_DIR/proxy_temp" \
  "$RUNTIME_DIR/fastcgi_temp" \
  "$RUNTIME_DIR/uwsgi_temp" \
  "$RUNTIME_DIR/scgi_temp"

DEFAULT_UID="$(id -u lnreader)"
DEFAULT_GID="$(id -g lnreader)"

if [ -z "$PUID" ]; then
  STORAGE_UID="$(stat -c '%u' "$STORAGE_DIR" 2>/dev/null || printf '%s' "$DEFAULT_UID")"
  if [ "$STORAGE_UID" -gt 0 ] 2>/dev/null; then
    PUID="$STORAGE_UID"
  else
    PUID="$DEFAULT_UID"
  fi
fi

if [ -z "$PGID" ]; then
  STORAGE_GID="$(stat -c '%g' "$STORAGE_DIR" 2>/dev/null || printf '%s' "$DEFAULT_GID")"
  if [ "$STORAGE_GID" -gt 0 ] 2>/dev/null; then
    PGID="$STORAGE_GID"
  else
    PGID="$DEFAULT_GID"
  fi
fi

case "$PUID:$PGID" in
  *[!0-9:]*|:*|*:)
    echo "ERROR: PUID and PGID must be blank or positive numeric IDs" >&2
    exit 64
    ;;
esac

if [ "$PUID" -eq 0 ] || [ "$PGID" -eq 0 ]; then
  echo "ERROR: PUID and PGID may not be 0; the service must run non-root" >&2
  exit 64
fi

if [ "$(id -g lnreader)" != "$PGID" ]; then
  groupmod -o -g "$PGID" lnreader
fi
if [ "$(id -u lnreader)" != "$PUID" ]; then
  usermod -o -u "$PUID" lnreader
fi

printf '{"workspace":"%s"}\n' "$STORAGE_DIR" > "$STORAGE_DIR/config.json"
printf '{"uploads":{}}\n' > "$RUNTIME_DIR/uploads.json"
date +%s > "$RUNTIME_DIR/started_at"

LNREADER_STORAGE_DIR="$STORAGE_DIR" \
LNREADER_RUNTIME_DIR="$RUNTIME_DIR" \
WEB_UI_SLUG="$WEB_UI_SLUG" \
WEB_UI_USERNAME="${WEB_UI_USERNAME:-admin}" \
WEB_UI_PASSWORD="${WEB_UI_PASSWORD:-}" \
  /bin/sh /app/docker/init-webui-auth.sh

case "$FIX_PERMISSIONS" in
  true|TRUE|1|yes|YES)
    chown -R lnreader:lnreader "$STORAGE_DIR"
    ;;
  false|FALSE|0|no|NO)
    ;;
  *)
    echo "ERROR: FIX_PERMISSIONS must be true or false" >&2
    exit 64
    ;;
esac

chown -R lnreader:lnreader "$RUNTIME_DIR"

sed \
  -e "s/__PORT__/$PORT/g" \
  -e "s/__WEB_UI_SLUG__/$WEB_UI_SLUG/g" \
  -e "s/__MAX_UPLOAD_SIZE__/$MAX_UPLOAD_SIZE/g" \
  /app/docker/nginx.conf.template > /etc/nginx/nginx.conf

export HOME=/home/lnreader
export LNREADER_STORAGE_DIR="$STORAGE_DIR"
export LNREADER_RUNTIME_DIR="$RUNTIME_DIR"
export WEB_UI_SLUG
export PUBLIC_URL
export PORT

if [ "$#" -gt 0 ]; then
  exec gosu lnreader "$@"
fi

exec gosu lnreader /usr/bin/supervisord -c /app/docker/supervisord.conf
