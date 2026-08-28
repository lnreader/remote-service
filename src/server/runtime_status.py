"""Concurrent runtime upload status shared with the read-only web UI."""

from __future__ import annotations

import fcntl
import json
import os
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


def runtime_dir() -> Path:
    path = Path(os.environ.get("LNREADER_RUNTIME_DIR", "/run/lnreader"))
    path.mkdir(parents=True, exist_ok=True)
    return path


def status_path() -> Path:
    return runtime_dir() / "uploads.json"


def lock_path() -> Path:
    return runtime_dir() / "uploads.lock"


@contextmanager
def _locked_state() -> Iterator[dict]:
    lock = lock_path()
    with lock.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        path = status_path()
        try:
            state = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"uploads": {}}
        except (json.JSONDecodeError, OSError):
            state = {"uploads": {}}
        if not isinstance(state, dict) or not isinstance(state.get("uploads"), dict):
            state = {"uploads": {}}
        yield state
        tmp = path.with_suffix(f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(state, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)


def reset_status() -> None:
    with _locked_state() as state:
        state["uploads"] = {}


def update_upload(upload_id: str, **fields: object) -> None:
    now = time.time()
    with _locked_state() as state:
        uploads = state["uploads"]
        # Remove abandoned entries after 6 hours. This only cleans status data,
        # never backup files.
        stale_before = now - 6 * 60 * 60
        for key in list(uploads):
            try:
                updated = float(uploads[key].get("updated_at", 0))
            except (TypeError, ValueError, AttributeError):
                updated = 0
            if updated < stale_before:
                uploads.pop(key, None)
        entry = uploads.setdefault(upload_id, {})
        entry.update(fields)
        entry["updated_at"] = now


def remove_upload(upload_id: str) -> None:
    with _locked_state() as state:
        state["uploads"].pop(upload_id, None)
