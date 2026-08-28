# Security

## Web UI Credentials

A fresh deployment automatically generates a cryptographically random password for the default admin user.

The runtime Nginx credential is stored as bcrypt.

For one-command deployment and later recovery, the generated username and plaintext password are also persisted under /home/lnreader/.LNReader/.webui-auth inside the mounted storage directory.

The credential directory uses mode 0700 and its credential files use mode 0600.

Treat the persistent LNReader storage directory as sensitive data.

WEB_UI_USERNAME and WEB_UI_PASSWORD can replace the generated credential. Protect any .env file containing a password and do not commit it.

Passwords are supplied to htpasswd through standard input rather than as a command-line password argument.

## Runtime Privileges

The container entrypoint performs required initialization as root and then starts Supervisor as the non-root lnreader user.

PUID and PGID overrides may not be 0.

Nginx, PHP-FPM, Gunicorn, and Supervisor run as the non-root service identity after initialization.

## Status Console

The status console is read-only and contains no JavaScript.

It uses HTTP Basic Auth, per-client rate limiting, a restrictive Content Security Policy, no-store and no-index headers, anti-frame protection, no-sniff protection, and no-referrer behavior.

The uncommon status path reduces routine scanning noise but is not a security boundary.

## Transport Security

HTTP Basic Auth does not encrypt credentials or traffic.

Use HTTPS or a trusted encrypted VPN on untrusted networks.

## LNReader API

The LNReader-compatible backup API remains unauthenticated for client compatibility.

The status-console password does not protect the root API, health endpoint, list endpoint, upload endpoint, or download endpoint.

Avoid directly exposing container port 8000 to the public Internet without appropriate external network controls.

## Upload Safety

Backup names and filenames are constrained beneath the configured storage root.

Uploads use hidden temporary files, streaming writes, fsync, and atomic replacement.

Active-upload state uses file locking and atomic replacement.
