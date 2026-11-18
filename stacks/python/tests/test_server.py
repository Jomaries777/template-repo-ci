import json
import threading
from collections.abc import Iterator
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from app.export import export
from app.routes import route
from app.server import create_server


@pytest.fixture
def base_url() -> Iterator[str]:
    server = create_server("127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()
    server.server_close()


def fetch(url: str, method: str = "GET") -> tuple[int, str, dict[str, object]]:
    try:
        with urlopen(Request(url, method=method)) as res:  # noqa: S310
            return res.status, res.headers["content-type"], json.loads(res.read())
    except HTTPError as err:
        return err.code, err.headers["content-type"], json.loads(err.read())


def test_root_returns_hello(base_url: str) -> None:
    status, ctype, body = fetch(f"{base_url}/")
    assert status == 200
    assert ctype.startswith("application/json")
    assert body == {"message": "hello"}


def test_root_keeps_returning_200(base_url: str) -> None:
    for _ in range(3):
        assert fetch(f"{base_url}/")[0] == 200


def test_health_default_version(base_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("APP_VERSION", raising=False)
    assert fetch(f"{base_url}/health")[2] == {"status": "ok", "version": "dev"}


def test_health_app_version(base_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("APP_VERSION", "1.2.3-sha")
    assert fetch(f"{base_url}/health")[2] == {"status": "ok", "version": "1.2.3-sha"}


def test_healthz_is_not_served(base_url: str) -> None:
    # Cloud Run reserves some paths ending in "z": the health route is /health.
    assert fetch(f"{base_url}/healthz")[0] == 404


def test_unknown_route_and_method_are_404_json(base_url: str) -> None:
    assert fetch(f"{base_url}/missing") == (404, "application/json; charset=utf-8", {"error": "not found"})
    assert fetch(f"{base_url}/", method="POST")[0] == 404


def test_query_string_is_ignored() -> None:
    assert route("GET", "/") == (200, {"message": "hello"})


def test_export_writes_every_static_route(tmp_path: Path) -> None:
    written = export(tmp_path)
    assert sorted(p.relative_to(tmp_path).as_posix() for p in written) == ["health/index.html", "index.html"]
    assert json.loads((tmp_path / "index.html").read_text()) == {"message": "hello"}
    assert json.loads((tmp_path / "health/index.html").read_text())["status"] == "ok"
