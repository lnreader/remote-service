#!/bin/sh
set -eu

STORAGE_DIR="${LNREADER_STORAGE_DIR:-/home/lnreader/.LNReader}"
RUNTIME_DIR="${LNREADER_RUNTIME_DIR:-/run/lnreader}"
WEB_UI_SLUG="${WEB_UI_SLUG:-lnr-vault-7f3c9}"
REQUESTED_USERNAME="${WEB_UI_USERNAME:-admin}"
REQUESTED_PASSWORD="${WEB_UI_PASSWORD:-}"
AUTH_DIR="${WEB_UI_AUTH_DIR:-$STORAGE_DIR/.webui-auth}"
USER_FILE="$AUTH_DIR/username"
PASSWORD_FILE="$AUTH_DIR/password"
HTPASSWD_FILE="$RUNTIME_DIR/.htpasswd"
GENERATED=0
CUSTOM=0

case "$REQUESTED_USERNAME" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: WEB_UI_USERNAME may contain only letters, digits, dot, underscore and dash" >&2
    exit 64
    ;;
esac

umask 077
mkdir -p "$AUTH_DIR" "$RUNTIME_DIR"
chmod 0700 "$AUTH_DIR"

if [ -n "$REQUESTED_PASSWORD" ]; then
  AUTH_USERNAME="$REQUESTED_USERNAME"
  AUTH_PASSWORD="$REQUESTED_PASSWORD"
  CUSTOM=1
  printf '%s' "$AUTH_USERNAME" > "$USER_FILE"
  printf '%s' "$AUTH_PASSWORD" > "$PASSWORD_FILE"
elif [ -s "$USER_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
  AUTH_USERNAME="$(cat "$USER_FILE")"
  AUTH_PASSWORD="$(cat "$PASSWORD_FILE")"
else
  AUTH_USERNAME="$REQUESTED_USERNAME"
  AUTH_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  GENERATED=1
  printf '%s' "$AUTH_USERNAME" > "$USER_FILE"
  printf '%s' "$AUTH_PASSWORD" > "$PASSWORD_FILE"
fi

case "$AUTH_USERNAME" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: persisted Web UI username is invalid" >&2
    exit 78
    ;;
esac

if [ -z "$AUTH_PASSWORD" ]; then
  echo "ERROR: Web UI password may not be empty" >&2
  exit 78
fi

# -i reads the password from stdin so it never appears in the process argv.
printf '%s\n' "$AUTH_PASSWORD" | htpasswd -Bni "$AUTH_USERNAME" > "$HTPASSWD_FILE"
chmod 0600 "$USER_FILE" "$PASSWORD_FILE" "$HTPASSWD_FILE"

if ! grep -Eq '^[^:#[:space:]]+:\$2[aby]\$' "$HTPASSWD_FILE"; then
  echo "ERROR: failed to create bcrypt Web UI credentials" >&2
  exit 78
fi

if [ "$GENERATED" -eq 1 ]; then
  cat <<EOF2

============================================================
LNReader Web UI credentials generated automatically
============================================================
Dashboard path: /$WEB_UI_SLUG/
Username: $AUTH_USERNAME
Password: $AUTH_PASSWORD

The credentials are persisted in:
  $AUTH_DIR

They will NOT change on normal container restarts/recreates.
To choose your own credentials, set WEB_UI_USERNAME and
WEB_UI_PASSWORD in .env, then recreate the container.
============================================================

EOF2
elif [ "$CUSTOM" -eq 1 ]; then
  echo "INFO: Web UI credentials updated from WEB_UI_USERNAME/WEB_UI_PASSWORD."
else
  echo "INFO: Reusing persisted Web UI credentials for user '$AUTH_USERNAME'."
fi
