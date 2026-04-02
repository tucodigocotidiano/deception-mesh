#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

OUTFILE = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/deceptionmesh_webhooks.jsonl")
PORT = int(sys.argv[2] if len(sys.argv) > 2 else "18080")


class Handler(BaseHTTPRequestHandler):
    def write_json(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path != "/health":
            self.write_json(404, {"ok": False, "detail": "not_found"})
            return

        self.write_json(
            200,
            {
                "ok": True,
                "service": "mock_webhook_receiver",
                "port": PORT,
                "capture_file": str(OUTFILE),
            },
        )

    def do_POST(self):
        if self.path != "/hook":
            self.write_json(404, {"ok": False, "detail": "not_found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)

        OUTFILE.parent.mkdir(parents=True, exist_ok=True)
        with OUTFILE.open("ab") as fh:
            fh.write(body)
            fh.write(b"\n")

        self.write_json(200, {"ok": True})

    def log_message(self, format, *args):
        return


def main():
    OUTFILE.parent.mkdir(parents=True, exist_ok=True)
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(
        f"mock webhook receiver listening on :{PORT}, writing to {OUTFILE}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()