"""Acceptance suite against a running service at BASE_URL. `make smoke` runs
only the tests marked `prod_safe` (read-only, safe against production).

Paths are relative ("health", not "/health"), so the suite also works when
the site lives under a sub-path, like GitHub Pages' https://<owner>.github.io/<repo>/.
"""

import os
from collections.abc import Iterator

import httpx
import pytest


@pytest.fixture(scope="module")
def client() -> Iterator[httpx.Client]:
    base = os.environ.get("BASE_URL", "http://localhost:8080")
    with httpx.Client(base_url=base.rstrip("/") + "/", follow_redirects=True, timeout=10) as c:
        yield c


@pytest.mark.prod_safe
def test_health_returns_ok(client: httpx.Client) -> None:
    res = client.get("health")
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "ok"
    assert isinstance(body["version"], str) and body["version"]


@pytest.mark.prod_safe
def test_root_returns_hello(client: httpx.Client) -> None:
    res = client.get("")
    assert res.status_code == 200
    assert res.json() == {"message": "hello"}


def test_unknown_returns_404_json(client: httpx.Client) -> None:
    res = client.get("unknown")
    assert res.status_code == 404
    assert res.json() == {"error": "not found"}
