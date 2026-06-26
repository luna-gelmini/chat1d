#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = os.environ.get("CHAT1_BLOB_HOST", "127.0.0.1")
PORT = int(os.environ.get("CHAT1_BLOB_PORT", "8090"))
STORE = os.environ.get(
    "CHAT1_BLOB_DIR", os.path.join(os.path.dirname(__file__), ".blob-store")
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"blob: {fmt % args}\n")

    def _cid_path(self) -> str | None:
        cid = self.path.lstrip("/").split("/", 1)[0]
        if not cid or "/" in cid or ".." in cid:
            return None
        return os.path.join(STORE, cid)

    def do_PUT(self) -> None:
        path = self._cid_path()
        if path is None:
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        data = self.rfile.read(length) if length > 0 else b""
        os.makedirs(STORE, exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        path = self._cid_path()
        if path is None or not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> int:
    os.makedirs(STORE, exist_ok=True)
    print(f"blob store {STORE} on http://{HOST}:{PORT}/<cid>", file=sys.stderr)
    HTTPServer((HOST, PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
