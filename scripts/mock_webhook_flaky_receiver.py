#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

OUTFILE = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/deceptionmesh_webhooks_flaky.jsonl")
PORT = int(sys.argv[2] if len(sys.argv) > 2 else "18081")
FAIL_FIRST = int(sys.argv[3] if len(sys.argv) > 3 else "3")
STATEFILE = OUTFILE.with_suffix(".state.json")


def load_counter() -> int:
    if not STATEFILE.exists():
        return 0
    try:
        return int(json.loads(STATEFILE.read_text()).get("count", 0))
    except Exception:
        return 0


def save_counter(count: int) -> None:
    STATEFILE.parent.mkdir(parents=True, exist_ok=True)
    STATEFILE.write_text(json.dumps({"count": count}))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":false,"detail":"not_found"}')
            return

        payload = {
            "ok": True,
            "service": "mock_webhook_flaky_receiver",
            "port": PORT,
            "fail_first": FAIL_FIRST,
            "count": load_counter(),
        }
        body = json.dumps(payload).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/hook":
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":false,"detail":"not_found"}')
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)

        count = load_counter() + 1
        save_counter(count)

        OUTFILE.parent.mkdir(parents=True, exist_ok=True)
        with OUTFILE.open("ab") as fh:
            fh.write(body)
            fh.write(b"\n")

        if count <= FAIL_FIRST:
            payload = {"ok": False, "attempt": count, "forced_failure": True}
            raw = json.dumps(payload).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        payload = {"ok": True, "attempt": count}
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):
        return


def main():
    OUTFILE.parent.mkdir(parents=True, exist_ok=True)
    STATEFILE.parent.mkdir(parents=True, exist_ok=True)
    save_counter(0)

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(
        f"flaky webhook receiver listening on :{PORT}, writing to {OUTFILE}, failing first {FAIL_FIRST}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()