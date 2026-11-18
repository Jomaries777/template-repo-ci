"""The service's routes as one pure function, shared by the HTTP server and
the static export (`make build-static`), so both always answer the same."""

import os
from typing import Any

Response = tuple[int, dict[str, Any]]


def route(method: str, path: str) -> Response:
    """Return (status, JSON body) for a request. Never raises."""
    if method == "GET" and path == "/":
        return 200, {"message": "hello"}
    # Not /healthz: Cloud Run reserves some paths that end in "z".
    if method == "GET" and path == "/health":
        return 200, {"status": "ok", "version": os.environ.get("APP_VERSION", "dev")}
    return 404, {"error": "not found"}


# GET routes that `make build-static` renders to files for static hosts.
STATIC_ROUTES = ("/", "/health")
