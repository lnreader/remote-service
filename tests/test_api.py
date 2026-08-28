from __future__ import annotations

import io
import json
from pathlib import Path
from urllib.parse import quote

import pytest

from src.server.server import app


def request(
    method: str,
    path: str,
    body: bytes = b"",
    *,
    stream=None,
    content_length: int | None = None,
    omit_content_length: bool = False,
):
    captured: dict[str, object] = {}

    def start_response(status, headers):
        captured["status"] = status
        captured["headers"] = dict(headers)

    environ = {
        "REQUEST_METHOD": method,
        "PATH_INFO": path,
        "wsgi.input": stream if stream is not None else io.BytesIO(body),
    }

    if omit_content_length:
        environ["wsgi.input_terminated"] = True
    else:
        environ["CONTENT_LENGTH"] = str(
            len(body) if content_length is None else content_length
        )
    response = app(environ, start_response)
    try:
        payload = b"".join(response)
    finally:
        close = getattr(response, "close", None)
        if close:
            close()
    return int(str(captured["status"]).split()[0]), captured["headers"], payload


@pytest.fixture()
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("LNREADER_STORAGE_DIR", str(tmp_path / "storage"))
    monkeypatch.setenv("LNREADER_RUNTIME_DIR", str(tmp_path / "runtime"))
    workspace = tmp_path / "storage"
    workspace.mkdir()
    return workspace


def test_root(workspace: Path):
    status, _, body = request("GET", "/")
    assert status == 200
    assert json.loads(body) == {"name": "LNReader"}


def test_health(workspace: Path):
    status, _, body = request("GET", "/healthz")
    assert status == 200
    assert json.loads(body) == {"status": "ok"}


def test_upload_list_download_round_trip(workspace: Path):
    payload = b"LNReader backup payload\x00\x01"
    status, _, body = request("POST", "/upload/test.backup&&data.zip", payload)
    assert status == 200
    assert json.loads(body)["size"] == len(payload)
    assert (workspace / "test.backup" / "data.zip").read_bytes() == payload

    status, _, body = request("GET", "/list")
    assert status == 200
    assert json.loads(body) == ["test.backup"]

    status, headers, body = request("GET", "/download/test.backup&&data.zip")
    assert status == 200
    assert headers["Content-Length"] == str(len(payload))
    assert body == payload


def test_nested_filename_round_trip(workspace: Path):
    payload = b"nested"
    path = "/upload/novels.backup&&nested/chapter/data.zip"
    assert request("POST", path, payload)[0] == 200
    assert request("GET", "/download/novels.backup&&nested/chapter/data.zip")[2] == payload


def test_streaming_upload_without_content_length(workspace: Path):
    payload = (b"streaming-lnreader-backup-" * 65536) + b"EOF"

    status, _, body = request(
        "POST",
        "/upload/chunked.backup&&data.zip",
        payload,
        omit_content_length=True,
    )

    assert status == 200

    decoded = json.loads(body)
    assert decoded["size"] == len(payload)

    saved = workspace / "chunked.backup" / "data.zip"
    assert saved.read_bytes() == payload


def test_missing_download_is_404(workspace: Path):
    assert request("GET", "/download/missing.backup&&data.zip")[0] == 404


@pytest.mark.parametrize(
    "path",
    [
        "/upload/../outside.backup&&data.zip",
        "/upload/safe.backup&&../../outside.zip",
        "/upload/" + quote("../outside.backup&&data.zip", safe="&"),
    ],
)
def test_traversal_attempt_is_rejected(workspace: Path, path: str):
    assert request("POST", path, b"bad")[0] == 400


def test_short_request_body_is_rejected_without_partial_backup(workspace: Path):
    status, _, body = request(
        "POST",
        "/upload/incomplete.backup&&data.zip",
        stream=io.BytesIO(b"short"),
        content_length=100,
    )
    assert status == 400
    assert b"Content-Length" in body
    assert not (workspace / "incomplete.backup" / "data.zip").exists()
    assert not list(workspace.rglob("*.part"))


def test_runtime_upload_status_is_visible_during_stream_and_cleaned_after_success(workspace: Path, tmp_path: Path):
    payload = b"x" * (2 * 1024 * 1024 + 25)
    observed: list[dict] = []

    class ObservingStream(io.BytesIO):
        reads = 0

        def read(self, size: int = -1) -> bytes:
            self.reads += 1
            if self.reads == 2:
                status_file = tmp_path / "runtime" / "uploads.json"
                if status_file.exists():
                    observed.append(json.loads(status_file.read_text()))
            return super().read(size)

    stream = ObservingStream(payload)
    status, _, _ = request(
        "POST",
        "/upload/status.backup&&big.bin",
        stream=stream,
        content_length=len(payload),
    )
    assert status == 200
    assert observed and observed[0]["uploads"]
    active = next(iter(observed[0]["uploads"].values()))
    assert active["backup_name"] == "status.backup"
    assert active["filename"] == "big.bin"
    assert active["bytes_received"] == 1024 * 1024
    state = json.loads((tmp_path / "runtime" / "uploads.json").read_text())
    assert state == {"uploads": {}}


def test_unknown_route_is_404(workspace: Path):
    assert request("GET", "/nope")[0] == 404
