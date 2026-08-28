# syntax=docker/dockerfile:1.7.0@sha256:dbbd5e059e8a07ff7ea6233b213b36aa516b4c53c645f1817a4dd18b83cbea56
FROM python:3.13.15-slim-bookworm

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG SOURCE_URL=https://github.com/lnreader/remote-service

ARG APACHE2_UTILS_VERSION=2.4.68-1~deb12u1
ARG GOSU_VERSION=1.14-1+b10
ARG NGINX_VERSION=1.22.1-9+deb12u9
ARG PHP_FPM_VERSION=8.2.33-1~deb12u1
ARG SUPERVISOR_VERSION=4.2.5-1

LABEL org.opencontainers.image.title="LNReader Remote Service" \
      org.opencontainers.image.description="Prebuilt LNReader backup server with a secured read-only status console" \
      org.opencontainers.image.source="$SOURCE_URL" \
      org.opencontainers.image.documentation="$SOURCE_URL#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$VCS_REF" \
      org.opencontainers.image.created="$BUILD_DATE"

ENV APP_VERSION=${VERSION} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/home/lnreader \
    LNREADER_STORAGE_DIR=/home/lnreader/.LNReader \
    LNREADER_RUNTIME_DIR=/run/lnreader \
    INTERNAL_API_PORT=8001 \
    PORT=8000 \
    WEB_UI_SLUG=lnr-vault-7f3c9 \
    MAX_UPLOAD_SIZE=20g

WORKDIR /app

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apache2-utils="${APACHE2_UTILS_VERSION}" \
        gosu="${GOSU_VERSION}" \
        nginx="${NGINX_VERSION}" \
        php8.2-fpm="${PHP_FPM_VERSION}" \
        supervisor="${SUPERVISOR_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 lnreader \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin lnreader

COPY requirements-docker.txt ./
RUN python -m pip install --no-cache-dir --requirement requirements-docker.txt

COPY src ./src
COPY docker ./docker
COPY web ./web

RUN chmod 0755 /app/docker/docker-entrypoint.sh /app/docker/init-webui-auth.sh \
    && mkdir -p /home/lnreader/.LNReader /run/lnreader \
    && chown -R lnreader:lnreader /home/lnreader /run/lnreader /app

EXPOSE 8000
VOLUME ["/home/lnreader/.LNReader"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3).read()" || exit 1

ENTRYPOINT ["/app/docker/docker-entrypoint.sh"]
