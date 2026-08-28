#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH="${PYTHONPATH:-}:$(pwd)"

banner() { printf '\n\n========== %s ==========\n' "$1"; }

banner "Environment"
python3 --version
printf 'repo=%s\n' "$(pwd)"

banner "Shell syntax"
for script in docker/*.sh scripts/*.sh; do
  bash -n "$script" 2>/dev/null || sh -n "$script"
  printf 'PASS: %s\n' "$script"
done

banner "Python compileall"
python3 -m compileall -q -f src tests scripts
printf 'PASS: compileall\n'

banner "Static repository validation"
python3 scripts/validate.py

banner "Pytest"
if python3 -c 'import pytest' >/dev/null 2>&1; then
  python3 -m pytest -vv -ra
else
  echo 'SKIP: pytest is not installed in this environment.'
  echo '      Install requirements-test.txt to run the Python suite locally.'
fi

banner "Live HTTP integration"
python3 scripts/live-http-test.py

banner "Web UI validation"
if [[ "${RUN_WEBUI_TESTS:-1}" == "1" ]]; then
  ./scripts/webui-test.sh
else
  echo 'SKIP: Web UI tests disabled for this test run.'
fi

banner "Docker/Compose validation"
if [[ "${RUN_DOCKER_TESTS:-1}" == "1" ]] \
  && command -v docker >/dev/null 2>&1 \
  && docker compose version >/dev/null 2>&1 \
  && docker info >/dev/null 2>&1; then
  docker compose -f docker-compose.yml config
  docker build --progress=plain --tag lnreader-remote-service:test .
  ./scripts/container-smoke-test.sh lnreader-remote-service:test
else
  echo 'SKIP: a usable Docker Engine with Compose is unavailable or Docker tests are disabled.'
fi

banner "Done"
