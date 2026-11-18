"""Standard-library HTTP server for the routes in `routes.py`."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from app.routes import route


class Handler(BaseHTTPRequestHandler):
    server_version = "app"
    sys_version = ""

    def _respond(self) -> None:
        status, body = route(self.command, urlsplit(self.path).path)
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_GET = _respond  # noqa: N815 (http.server API)
    do_POST = _respond  # noqa: N815 (http.server API)
    do_PUT = _respond  # noqa: N815 (http.server API)
    do_PATCH = _respond  # noqa: N815 (http.server API)
    do_DELETE = _respond  # noqa: N815 (http.server API)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Quiet by default; Cloud Run and compose log requests themselves."""


def create_server(host: str = "0.0.0.0", port: int = 8080) -> ThreadingHTTPServer:  # noqa: S104
    return ThreadingHTTPServer((host, port), Handler)
