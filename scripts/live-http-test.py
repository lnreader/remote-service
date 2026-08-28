#!/usr/bin/env python3
"""Start the service on localhost and exercise the real HTTP interface."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def fetch(url: str, *, data: bytes | None = None, method: str = "GET"):
    request = urllib.request.Request(url, data=data, method=method)
    return urllib.request.urlopen(request, timeout=2)


def main() -> int:
    port = free_port()
    with tempfile.TemporaryDirectory(prefix="lnreader-http-test-") as tmp:
        env = os.environ.copy()
        env.update(
            {
                "PYTHONPATH": str(ROOT),
                "LNREADER_STORAGE_DIR": tmp,
                "LNREADER_RUNTIME_DIR": str(Path(tmp) / "run"),
                "HOST": "127.0.0.1",
                "PORT": str(port),
            }
        )
        process = subprocess.Popen(
            [sys.executable, "-m", "src.server.server"],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        base = f"http://127.0.0.1:{port}"
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise RuntimeError("server exited before becoming healthy")
                try:
                    with fetch(base + "/healthz") as response:
                        if response.status == 200:
                            print(f"PASS: healthz on port {port}")
                            break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("server did not become healthy")

            payload = b"live-http-integration-test-12345"
            with fetch(base + "/upload/live.backup&&nested/data.zip", data=payload, method="POST") as response:
                result = json.loads(response.read())
                assert result["size"] == len(payload)
                print(f"PASS: upload {len(payload)} bytes")

            with fetch(base + "/list") as response:
                result = json.loads(response.read())
                assert result == ["live.backup"]
                print("PASS: list backup")

            with fetch(base + "/download/live.backup&&nested/data.zip") as response:
                assert response.read() == payload
                print("PASS: download round trip")

            try:
                fetch(base + "/upload/safe.backup&&../../escape.zip", data=b"bad", method="POST")
                raise AssertionError("traversal request unexpectedly succeeded")
            except urllib.error.HTTPError as exc:
                assert exc.code == 400
                print("PASS: live traversal rejection")

            return 0
        finally:
            process.terminate()
            try:
                output, _ = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                output, _ = process.communicate()
            print("\n--- server output ---")
            print(output.rstrip())


if __name__ == "__main__":
    raise SystemExit(main())
