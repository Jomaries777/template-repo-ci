# Python Stack (standard library `http.server`)

A minimal Python 3.13 HTTP service with no runtime dependencies. Dev tools are hash-pinned in `requirements-dev.txt`.

## Endpoints

- `GET /` returns `200 {"message":"hello"}`.
- `GET /health` returns `200 {"status":"ok","version":"<APP_VERSION|dev>"}`. It isn't `/healthz` because Cloud Run reserves some paths that end in `z`, so keep new routes off them too.
- Any other path or method returns `404 {"error":"not found"}`.

Every route lives in one function, `src/app/routes.py`. The HTTP server and the static export both use it.

## Make targets

| Target | What it does |
|---|---|
| `make install` | Create `.venv` from `requirements-dev.txt` (`pip --require-hashes`). Other targets do this on demand. |
| `make fmt` | Format with ruff. |
| `make lint` | Lint and check formatting with ruff. |
| `make typecheck` | Type-check with `mypy --strict`. |
| `make test` | Run the pytest unit tests in `tests/`. |
| `make build` | Build the `app:local` image. |
| `make build-static` | Render the GET routes to `dist/static/` (`index.html`, `health/index.html`) for static hosts such as GitHub Pages. |
| `make acceptance` | Start `compose.yaml`, run `acceptance/` with httpx, then tear it down. |
| `make smoke URL=<url>` | Run only the `prod_safe` acceptance tests against `URL`. |

The acceptance tests use relative paths (`health`, not `/health`). That way they also pass when the site lives under a sub-path, like GitHub Pages.

## Dependencies

- Edit `requirements-dev.in`, then regenerate the pins with `pip-compile --generate-hashes --allow-unsafe --strip-extras -o requirements-dev.txt requirements-dev.in`.
- Dependabot keeps the pins current. `dependabot-updates.yml` is the config, and bootstrap appends it to `.github/dependabot.yml`. The bot approves patch updates and they auto-merge; minor and major updates wait for the owner.
- The `cloudflare-workers` target doesn't support this stack, because Workers run JavaScript.
