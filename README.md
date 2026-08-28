# LNReader Remote Service

LNReader Remote Service provides self-hosted backup and restore support for LNReader.

**Required LNReader version:** 2.0.0 or newer.

The existing desktop GUI and command-line service remain supported. Docker users can also run the service as a hardened non-root container with a read-only status dashboard.

# Docker Quick Start

Docker Engine or Docker Desktop with Docker Compose is required.

```bash
docker compose up -d
```

The default API address is:

```text
http://HOST:8000
```

Use that address in LNReader under Settings, Backup, Self Host Backup.

The default status dashboard path is:

```text
http://HOST:8000/lnr-vault-7f3c9/
```

On first startup the container creates the default Web UI user **admin** and a random password. The password is persisted in the storage directory and is printed once in the initial container logs.

```bash
docker compose logs lnreader
```

The generated credentials can also be read from:

```text
./data/.webui-auth/
```

# Configuration

A .env file is optional. Copy .env.example only when changing defaults.

```bash
cp .env.example .env
```

The default image is:

```text
ghcr.io/lnreader/remote-service:latest
```

The default host port is:

```text
8000
```

The default storage path is:

```text
./data
```

The default Web UI username is:

```text
admin
```

Leave WEB_UI_PASSWORD empty to generate and persist a random password automatically.

To choose a password explicitly, set the following values in .env and recreate the service.

```text
WEB_UI_USERNAME=admin
WEB_UI_PASSWORD=replace-with-a-long-password
```

```bash
docker compose up -d --force-recreate
```

PUID and PGID are optional Linux ownership overrides. Leave them blank unless the host requires a specific numeric owner for the mounted storage directory.

PUBLIC_URL is optional and is used only for the address displayed by the status dashboard. Include the URL scheme when setting it.

```text
PUBLIC_URL=https://lnreader.example.com
```

# API Compatibility

The LNReader backup API remains available without Web UI authentication so existing LNReader clients can continue using it.

```text
GET /
GET /healthz
GET /list
POST /upload/<backup>&&<filename>
GET /download/<backup>&&<filename>
```

The status dashboard is protected separately with HTTP Basic Authentication.

# Desktop GUI

The existing desktop GUI remains available through the project development environment.

```bash
pdm install
pdm run gui
```

The GUI can be packaged with the existing PyInstaller configuration.

```bash
pdm run build
```

# Command Line

The existing command-line service remains available.

```bash
pdm install
pdm run server 0.0.0.0 8000
```

Without explicit host and port arguments the server uses its default host and port settings.

# Security

The container runs the managed services as a non-root user.

Uploaded files are streamed to temporary files and committed with an atomic replacement after the complete request body is received.

Backup and filename paths are resolved beneath the configured storage directory and traversal attempts are rejected.

The status dashboard is read-only, protected by bcrypt-backed HTTP Basic Authentication, rate limited, and served with restrictive security headers.

The Docker socket is not mounted into the service.

The LNReader API itself is intentionally not protected by the dashboard password because doing so would change client compatibility. Do not expose the raw API port directly to the public Internet without an appropriate VPN, firewall, or reverse-proxy access policy.

# Development

Developer setup, tests, container validation, and CI behavior are documented in DEVELOPMENT.md.

Run the complete local validation suite with:

```bash
./scripts/test-verbose.sh
```

# License

MIT
