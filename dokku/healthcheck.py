#!/usr/bin/env python3
"""Hermes Agent — Dokku healthcheck sidecar.

A minimal aiohttp app that serves:
  GET /health       -> 200 "ok"            (Dokku CHECKS, fast path)
  GET /health/deep  -> 200 JSON status     (operator debugging)

Listens on 127.0.0.1:$PORT (default 9090). Bound to localhost so the gateway's
API server can use a different port for external traffic without collision.

Stdlib-only: we deliberately don't add aiohttp as a runtime dep. The upstream
image has the Python stdlib available; aiohttp would require a venv mutation
and the upstream Dockerfile seals /opt/hermes (HERMES_DISABLE_LAZY_INSTALLS=1).
"""

import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("HEALTHCHECK_PORT", "9090"))
GATEWAY_API_PORT = int(os.environ.get("API_SERVER_PORT", "9091"))


def gateway_reachable() -> bool:
    """TCP-connect probe to the gateway's API server on localhost."""
    try:
        with socket.create_connection(("127.0.0.1", GATEWAY_API_PORT), timeout=2):
            return True
    except OSError:
        return False


def s6_service_state(name: str) -> str:
    """Read s6 service state from /run/service/<name>/supervise.status.

    Returns "up", "down", or "unknown" if the file is missing/unreadable.
    The file is a small text file written by s6-supervise; first line is
    "up" or "down" followed by a timestamp.
    """
    try:
        with open(f"/run/service/{name}/supervise.status", "r") as f:
            first = f.readline().strip()
            return first if first in ("up", "down") else "unknown"
    except OSError:
        return "unknown"


def config_seeded() -> bool:
    """True if /opt/data/config.yaml exists and is non-empty."""
    try:
        return os.path.getsize("/opt/data/config.yaml") > 0
    except OSError:
        return False


class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Silence default access logging; Dokku captures docker logs instead.
        return

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path == "/health/deep":
            payload = {
                "healthcheck": "ok",
                "gateway_api_reachable": gateway_reachable(),
                "s6_main_hermes": s6_service_state("main-hermes"),
                "s6_dokku_healthcheck": s6_service_state("dokku-healthcheck"),
                "config_seeded": config_seeded(),
                "hermes_home": os.environ.get("HERMES_HOME", ""),
                "hermes_uid": os.getuid(),
            }
            body = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "9")
        self.end_headers()
        self.wfile.write(b"not found")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), HealthHandler)
    print(f"[hermes-healthcheck] listening on 127.0.0.1:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[hermes-healthcheck] shutting down", flush=True)
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
