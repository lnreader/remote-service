"""LNReader Remote Service WSGI API.

This keeps the upstream HTTP contract while using only Python's standard
library at runtime behind Gunicorn.
"""

from __future__ import annotations

import json
import mimetypes
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Iterable
from urllib.parse import unquote
from wsgiref.simple_server import make_server
from wsgiref.util import FileWrapper

from .runtime_status import remove_upload, update_upload
from .storage import get_workspace, safe_backup_path

JSON_HEADERS = [("Content-Type", "application/json; charset=utf-8")]
UPLOAD_CHUNK_SIZE = 1024 * 1024


def _json_response(start_response, status: str, payload: object) -> list[bytes]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    start_response(status, JSON_HEADERS + [("Content-Length", str(len(body)))])
    return [body]


def _route_parts(path: str, prefix: str) -> tuple[str, str] | None:
    if not path.startswith(prefix):
        return None
    value = unquote(path[len(prefix):])
    if "&&" not in value:
        return None
    backup_name, filename = value.split("&&", 1)
    if not backup_name or not filename:
        return None
    return backup_name, filename


def _stream_upload(
    environ: dict,
    file_path: Path,
    backup_name: str,
    filename: str,
    total: int | None,
) -> int:
    upload_id = uuid.uuid4().hex
    started_at = time.time()
    temp_path = file_path.with_name(
        f".{file_path.name}.upload-{upload_id}.part"
    )
    received = 0

    update_upload(
        upload_id,
        backup_name=backup_name,
        filename=filename,
        bytes_received=0,
        total_bytes=total if total is not None else 0,
        started_at=started_at,
    )

    try:
        file_path.parent.mkdir(parents=True, exist_ok=True)
        stream = environ["wsgi.input"]

        with temp_path.open("wb") as handle:
            if total is None:
                # Chunked / otherwise terminated request.
                #
                # Gunicorn exposes a decoded input stream and marks it with
                # wsgi.input_terminated. Read until EOF without ever
                # materializing the complete request body.
                while True:
                    chunk = stream.read(UPLOAD_CHUNK_SIZE)
                    if not chunk:
                        break

                    handle.write(chunk)
                    received += len(chunk)

                    update_upload(
                        upload_id,
                        bytes_received=received,
                    )
            else:
                # Fixed-length request. Keep the existing strict short-body
                # detection rather than silently accepting a truncated file.
                remaining = total

                while remaining > 0:
                    chunk = stream.read(
                        min(UPLOAD_CHUNK_SIZE, remaining)
                    )

                    if not chunk:
                        raise IOError(
                            "request body ended before Content-Length"
                        )

                    handle.write(chunk)
                    received += len(chunk)
                    remaining -= len(chunk)

                    update_upload(
                        upload_id,
                        bytes_received=received,
                    )

            handle.flush()
            os.fsync(handle.fileno())

        os.replace(temp_path, file_path)
        return received

    finally:
        try:
            temp_path.unlink(missing_ok=True)
        finally:
            remove_upload(upload_id)

def app(environ: dict, start_response) -> Iterable[bytes]:
    method = str(environ.get("REQUEST_METHOD", "GET")).upper()
    path = str(environ.get("PATH_INFO", "/"))

    if method == "GET" and path == "/":
        return _json_response(start_response, "200 OK", {"name": "LNReader"})

    if method == "GET" and path == "/healthz":
        workspace = get_workspace()
        if workspace.exists() and workspace.is_dir():
            return _json_response(start_response, "200 OK", {"status": "ok"})
        return _json_response(start_response, "503 Service Unavailable", {"error": "workspace unavailable"})

    if method == "GET" and path == "/list":
        workspace = Path(get_workspace())
        backups = [] if not workspace.exists() else sorted(
            folder.name
            for folder in workspace.iterdir()
            if folder.is_dir() and folder.name.endswith(".backup")
        )
        return _json_response(start_response, "200 OK", backups)

    upload_parts = _route_parts(path, "/upload/") if method == "POST" else None
    if upload_parts is not None:
        backup_name, filename = upload_parts
        try:
            file_path = safe_backup_path(get_workspace(), backup_name, filename)
        except ValueError:
            return _json_response(start_response, "400 Bad Request", {"error": "invalid backup path"})

        raw_content_length = str(
            environ.get("CONTENT_LENGTH") or ""
        ).strip()

        if raw_content_length:
            try:
                content_length: int | None = int(raw_content_length)
            except ValueError:
                return _json_response(
                    start_response,
                    "400 Bad Request",
                    {"error": "invalid content length"},
                )

            if content_length < 0:
                return _json_response(
                    start_response,
                    "400 Bad Request",
                    {"error": "invalid content length"},
                )
        else:
            # Streaming HTTP requests such as Transfer-Encoding: chunked do
            # not provide Content-Length. Only read until EOF when the WSGI
            # server explicitly says the input stream is terminated.
            if not bool(environ.get("wsgi.input_terminated")):
                return _json_response(
                    start_response,
                    "411 Length Required",
                    {"error": "content length required"},
                )

            content_length = None

        try:
            received = _stream_upload(environ, file_path, backup_name, filename, content_length)
        except (OSError, IOError) as exc:
            return _json_response(start_response, "400 Bad Request", {"error": str(exc)})

        return _json_response(
            start_response,
            "200 OK",
            {"backup_name": backup_name, "filename": filename, "size": received},
        )

    download_parts = _route_parts(path, "/download/") if method == "GET" else None
    if download_parts is not None:
        backup_name, filename = download_parts
        try:
            file_path = safe_backup_path(get_workspace(), backup_name, filename)
        except ValueError:
            return _json_response(start_response, "400 Bad Request", {"error": "invalid backup path"})

        if not file_path.is_file():
            return _json_response(start_response, "404 Not Found", {"error": "file not found"})

        size = file_path.stat().st_size
        content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
        download_name = file_path.name.replace('"', "_").replace("\r", "").replace("\n", "")
        headers = [
            ("Content-Type", content_type),
            ("Content-Length", str(size)),
            ("Content-Disposition", f'attachment; filename="{download_name}"'),
        ]
        start_response("200 OK", headers)
        handle = file_path.open("rb")
        wrapper = environ.get("wsgi.file_wrapper", FileWrapper)
        return wrapper(handle, 64 * 1024)

    return _json_response(start_response, "404 Not Found", {"error": "not found"})


def main() -> None:
    if len(sys.argv) == 1:
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", "8000"))
    else:
        host, port_arg = sys.argv[1], sys.argv[2]
        port = int(port_arg)

    print(f"Start server - {host}:{port}")
    with make_server(host, port, app) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
