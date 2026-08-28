# Development

This document covers development of LNReader Remote Service with emphasis on the self-hosted server and container path.

# Requirements

Python 3.10 or newer is required for the server test suite.

Docker Engine or Docker Desktop with Docker Compose is required for full container validation.

PHP CLI and apache2-utils are optional for local Web UI validation because the container smoke test also validates the runtime PHP and bcrypt configuration.

# Python Test Environment

Create an isolated environment and install the pinned test dependencies.

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-test.txt
```

Run the Python tests.

```bash
python -m pytest -vv -ra
```

Run static repository validation.

```bash
python scripts/validate.py
```

Run the live HTTP integration test.

```bash
python scripts/live-http-test.py
```

# Web UI Tests

Run the Web UI tests with:

```bash
./scripts/webui-test.sh
```

Run the automatic credential lifecycle tests with:

```bash
./scripts/webui-auth-test.sh
```

# Complete Validation

Run all locally available checks with:

```bash
./scripts/test-verbose.sh
```

When Docker is available this also builds the image and runs the complete container smoke test.

# Container Development

Build a local image with:

```bash
docker build --progress=plain -t lnreader-remote-service:local .
```

Run the container smoke test with:

```bash
./scripts/container-smoke-test.sh lnreader-remote-service:local
```

The smoke test verifies container health, non-root PID 1, Nginx configuration, API compatibility, dashboard authentication, active upload visibility, generated credential persistence, and explicit credential overrides.

# Docker Compose

Validate the Compose file with:

```bash
docker compose config
```

Start the normal service with:

```bash
docker compose up -d
```

Stop it with:

```bash
docker compose down
```

# Continuous Integration

The container workflow runs Python validation across the configured Python matrix, PHP and bcrypt tests, a full Docker smoke test, and a multi-architecture Buildx build.

Pull requests build the container without publishing it.

Pushes to the default branch and version tags can publish images to the repository GitHub Container Registry namespace when package write permission is available.

# Compatibility

Changes to the backup API should preserve the existing LNReader routes and response behavior unless a coordinated client change is planned.

The desktop GUI imports the server WSGI application and should remain usable after server changes.

The command-line entry point should continue to expose src.server.server:main.

# Security Review

Server changes should continue to reject path traversal, avoid buffering complete uploads in memory, clean incomplete temporary uploads, and avoid running container services as root.

The dashboard authentication boundary is separate from the LNReader backup API. Changes that add authentication to the backup API require explicit client compatibility review.
