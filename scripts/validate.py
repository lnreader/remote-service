#!/usr/bin/env python3
"""Offline/static repository validation used locally and in CI."""
from __future__ import annotations

import ast
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
errors: list[str] = []
passes: list[str] = []


def check(condition: bool, message: str) -> None:
    (passes if condition else errors).append(message)


for py_file in sorted(ROOT.rglob("*.py")):
    relative_parts = py_file.relative_to(ROOT).parts
    if any(
        part == "venv"
        or part.startswith(".venv")
        or part in {".git", ".tox", ".nox", "__pycache__"}
        for part in relative_parts
    ):
        continue
    try:
        ast.parse(py_file.read_text(encoding="utf-8"), filename=str(py_file))
        passes.append(f"python syntax: {py_file.relative_to(ROOT)}")
    except SyntaxError as exc:
        errors.append(f"python syntax: {py_file.relative_to(ROOT)}: {exc}")

for yaml_name in ["docker-compose.yml", ".github/workflows/container.yml"]:
    path = ROOT / yaml_name
    try:
        parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
        check(isinstance(parsed, dict), f"yaml parse: {yaml_name}")
    except Exception as exc:
        errors.append(f"yaml parse: {yaml_name}: {exc}")

compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
check("build:" not in compose, "compose uses prebuilt image only")
check("ghcr.io/lnreader/remote-service:latest" in compose, "compose defaults to the upstream GHCR image")
check("HOST_PORT" in compose and 'target: /home/lnreader/.LNReader' in compose, "compose uses portable host port and storage settings")
check("source: ${STORAGE_PATH:-./data}" in compose, "compose defaults to relative portable storage")
check('PUID: "${PUID:-}"' in compose and 'PGID: "${PGID:-}"' in compose, "compose does not assume host UID or GID")
check("container_name:" not in compose, "compose avoids a global fixed container name")
check("secrets:" not in compose and "HTPASSWD_PATH" not in compose, "compose needs no external htpasswd secret")
check("WEB_UI_PASSWORD" in compose and "WEB_UI_USERNAME" in compose, "compose exposes optional Web UI credential overrides")
check(not (ROOT / "docker-compose.omv.yml").exists(), "repository has no OS-specific Compose file")
check(not (ROOT / "scripts/create-htpasswd.sh").exists(), "obsolete external htpasswd helper removed")

pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
check('name = "remote-service"' in pyproject, "pyproject preserves upstream project identity")
check('gui = "python main.py"' in pyproject, "pyproject preserves desktop GUI entry point")
check('server = { call = "src.server.server:main" }' in pyproject, "pyproject preserves command-line server entry point")
for token in ["gunicorn==26.2.0", "packaging==26.3", "pytest==9.1.1", "PyYAML==6.0.3"]:
    check(token in pyproject or token in (ROOT / "requirements-test.txt").read_text() or token in (ROOT / "requirements-docker.txt").read_text(), f"dependency pin present: {token}")

dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
for token in [
    "docker/dockerfile:1.7.0@sha256:dbbd5e059e8a07ff7ea6233b213b36aa516b4c53c645f1817a4dd18b83cbea56",
    "python:3.13.15-slim-bookworm",
    "apache2-utils=\"${APACHE2_UTILS_VERSION}\"",
    "gosu=\"${GOSU_VERSION}\"",
    "nginx=\"${NGINX_VERSION}\"",
    "php8.2-fpm=\"${PHP_FPM_VERSION}\"",
    "supervisor=\"${SUPERVISOR_VERSION}\"",
    "HEALTHCHECK",
    "ENTRYPOINT",
]:
    check(token in dockerfile, f"Dockerfile pin/config contains {token}")
for version_pin in [
    "APACHE2_UTILS_VERSION=2.4.68-1~deb12u1",
    "GOSU_VERSION=1.14-1+b10",
    "NGINX_VERSION=1.22.1-9+deb12u9",
    "PHP_FPM_VERSION=8.2.33-1~deb12u1",
    "SUPERVISOR_VERSION=4.2.5-1",
]:
    check(version_pin in dockerfile, f"Dockerfile package pin present: {version_pin}")

workflow = (ROOT / ".github/workflows/container.yml").read_text(encoding="utf-8")
for token in [
    "actions/checkout@v7.0.1",
    "actions/setup-python@v7.0.0",
    "docker/setup-qemu-action@v4.2.0",
    "tonistiigi/binfmt:qemu-v10.2.3",
    "docker/setup-buildx-action@v4.2.0",
    "docker/login-action@v4.6.0",
    "docker/metadata-action@v6.2.0",
    "docker/build-push-action@v7.1.0",
    "actions/upload-artifact@v7.0.1",
    "linux/amd64,linux/arm64",
    "packages: write",
]:
    check(token in workflow, f"workflow pin/config contains {token}")
for python_version in ["3.10.11", "3.11.9", "3.12.10", "3.13.15", "3.14.7"]:
    check(python_version in workflow, f"CI Python version pinned: {python_version}")
check(not re.search(r"uses:\s+[^\n]+@v\d+\s*$", workflow, re.MULTILINE), "workflow avoids floating major-only action tags")

entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")
auth_init = (ROOT / "docker/init-webui-auth.sh").read_text(encoding="utf-8")
check(bool(re.search(r"exec\s+gosu\s+lnreader", entrypoint)), "entrypoint drops services to lnreader")
check('PUID="${PUID:-}"' in entrypoint and 'PGID="${PGID:-}"' in entrypoint, "entrypoint accepts blank UID and GID")
check('stat -c \'%u\'' in entrypoint and 'stat -c \'%g\'' in entrypoint, "entrypoint can reuse mounted storage ownership")
check('PUID" -eq 0' in entrypoint and 'PGID" -eq 0' in entrypoint, "entrypoint rejects root UID and GID")
check("init-webui-auth.sh" in entrypoint, "entrypoint initializes Web UI auth automatically")
smoke = (ROOT / "scripts/container-smoke-test.sh").read_text(encoding="utf-8")
check("-e PUID=" not in smoke and "-e PGID=" not in smoke, "container smoke test exercises automatic non-root UID and GID defaults")
check("secrets.token_urlsafe" in auth_init, "auth initializer uses cryptographic random password generation")
check("htpasswd -Bni" in auth_init, "auth initializer creates bcrypt without password argv exposure")
check(".webui-auth" in auth_init, "generated credentials persist inside storage volume")

nginx = (ROOT / "docker/nginx.conf.template").read_text(encoding="utf-8")
for token in ["auth_basic", "Content-Security-Policy", "limit_req", "limit_except GET POST", "X-Robots-Tag"]:
    check(token in nginx, f"nginx UI protection contains {token}")
check(
    "form-action 'self'" in nginx,
    "nginx CSP permits same-origin forms",
)
check("/admin" not in nginx.lower(), "dashboard does not use common /admin path")
for temp_path in [
    "client_body_temp_path /run/lnreader/client_temp",
    "proxy_temp_path /run/lnreader/proxy_temp",
    "fastcgi_temp_path /run/lnreader/fastcgi_temp",
    "uwsgi_temp_path /run/lnreader/uwsgi_temp",
    "scgi_temp_path /run/lnreader/scgi_temp",
]:
    check(temp_path in nginx, f"nginx non-root temp path: {temp_path.split()[0]}")
check("/var/lib/nginx" not in nginx, "nginx avoids root-owned runtime temp paths")

check(
    "map $http_x_forwarded_proto $lnreader_forwarded_proto" in nginx,
    "nginx normalizes forwarded proxy scheme",
)
check(
    "proxy_set_header X-Forwarded-Proto $lnreader_forwarded_proto;" in nginx,
    "nginx sends normalized X-Forwarded-Proto",
)
check(
    'proxy_set_header X-Forwarded-Ssl "";' in nginx,
    "nginx strips alternate X-Forwarded-Ssl",
)
check(
    'proxy_set_header X-Forwarded-Protocol "";' in nginx,
    "nginx strips alternate X-Forwarded-Protocol",
)

gunicorn_config = (ROOT / "docker/gunicorn.conf.py").read_text(encoding="utf-8")
check(
    'forwarded_allow_ips = "127.0.0.1"' in gunicorn_config,
    "gunicorn trusts forwarded headers only from internal Nginx",
)
check(
    '"X-FORWARDED-PROTO": "https"' in gunicorn_config,
    "gunicorn uses one normalized secure scheme header",
)

php = (ROOT / "web/index.php").read_text(encoding="utf-8")
for token in [
    "Current backup uploads",
    "Stored backups",
    "LNReader app server URL",
    "Delete permanently",
    "safe_backup_dir",
    "csrf_token",
    "delete_backup_tree",
    "backup_has_active_upload",
    "htmlspecialchars",
]:
    check(token in php, f"PHP dashboard contains {token}")
check("<script" not in php.lower(), "PHP dashboard contains no JavaScript")

runtime = (ROOT / "src/server/runtime_status.py").read_text(encoding="utf-8")
check("fcntl.flock" in runtime, "runtime upload status uses file locking")
check("os.replace" in (ROOT / "src/server/server.py").read_text(encoding="utf-8"), "uploads commit atomically")

readme = (ROOT / "README.md").read_text(encoding="utf-8")
readme_outside_fences: list[str] = []
in_fence = False
for line in readme.splitlines():
    if line.startswith("```"):
        in_fence = not in_fence
        continue
    if not in_fence:
        readme_outside_fences.append(line)
plain_readme = "\n".join(readme_outside_fences)
check(not re.search(r"^\s*[-*+]\s+", plain_readme, re.MULTILINE), "README uses no Markdown bullet lists")
check(not re.search(r"^\s*\d+\.\s+", plain_readme, re.MULTILINE), "README uses no numbered lists")
check("|---" not in readme and "---|" not in readme, "README uses no Markdown tables")
check("![" not in readme, "README uses no Markdown images")
check(not re.search(r"\[[^\]]+\]\([^\)]+\)", plain_readme), "README uses no Markdown link syntax")
check("OMV" not in readme and "OpenMediaVault" not in readme, "README is not tied to a specific host OS")

for required in ["README.md", "DEVELOPMENT.md", "SECURITY.md", "LICENSE", ".env.example"]:
    check((ROOT / required).exists(), f"repository includes {required}")

print("=== validation passes ===")
for item in passes:
    print(f"PASS: {item}")
print("\n=== validation failures ===")
for item in errors:
    print(f"FAIL: {item}")
print(f"\nSummary: {len(passes)} passed, {len(errors)} failed")
sys.exit(1 if errors else 0)
