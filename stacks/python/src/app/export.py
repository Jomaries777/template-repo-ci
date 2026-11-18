"""`python -m app.export <dir>`: render the GET routes to static files for
hosts that only serve files (GitHub Pages). `/` becomes `index.html` and
`/health` becomes `health/index.html`, so the same smoke suite passes against
the export served locally and against the live site."""

import json
import sys
from pathlib import Path

from app.routes import STATIC_ROUTES, route


def export(out: Path) -> list[Path]:
    written = []
    for path in STATIC_ROUTES:
        status, body = route("GET", path)
        if status != 200:
            raise SystemExit(f"export: GET {path} returned {status}")
        target = out / path.strip("/") / "index.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(body))
        written.append(target)
    return written


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python -m app.export <output dir>")
    for f in export(Path(sys.argv[1])):
        print(f)
