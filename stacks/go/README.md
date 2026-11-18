# Go Stack (standard library `net/http`)

A minimal Go HTTP service with no runtime dependencies. The image is a static binary on distroless, running as non-root.

## Endpoints

- `GET /` returns `200 {"message":"hello"}`.
- `GET /health` returns `200 {"status":"ok","version":"<APP_VERSION|dev>"}`. It isn't `/healthz` because Cloud Run reserves some paths that end in `z`, so keep new routes off them too.
- Any other path or method returns `404 {"error":"not found"}`.

Every route lives in one function, `internal/app/routes.go`. The HTTP server and the static export both use it. `app healthcheck` checks the running server; the compose healthcheck uses it, because distroless has no shell or curl.

## Make targets

| Target | What it does |
|---|---|
| `make fmt` | Format with `gofmt`. |
| `make lint` | Check `gofmt`, run `go vet` (acceptance included) and `staticcheck`, pinned as a `go.mod` tool and run with `go tool`. |
| `make typecheck` | Compile every package, the acceptance tests included. |
| `make test` | Run the unit tests (`go test ./...`). |
| `make build` | Build the `app:local` image. |
| `make build-static` | Render the GET routes to `dist/static/` (`index.html`, `health/index.html`) for static hosts such as GitHub Pages. |
| `make acceptance` | Start `compose.yaml`, run `acceptance/` (build tag `acceptance`), then tear it down. |
| `make smoke URL=<url>` | Run only the `ProdSafe` acceptance tests against `URL`. |

The acceptance tests use relative paths (`health`, not `/health`). That way they also pass when the site lives under a sub-path, like GitHub Pages.

## Dependencies

- The module is `example.com/app`. Rename it if you publish the code as a library.
- Dependabot keeps `go.mod` and the base images current. `dependabot-updates.yml` is the config, and bootstrap appends it to `.github/dependabot.yml`. The bot approves patch updates and they auto-merge; minor and major updates wait for the owner.
- The `cloudflare-workers` target doesn't support this stack, because Workers run JavaScript.
