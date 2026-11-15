# Node Stack (TypeScript + `node:http`)

Minimal Node 22 HTTP service with zero runtime framework dependencies.

## Endpoints

- `GET /` — returns `200 {"message":"hello"}`
- `GET /healthz` — returns `200 {"status":"ok","version":"<APP_VERSION|dev>"}`
- Any other path or method — returns `404 {"error":"not found"}`

## Make Targets

- `make install` — install locked dependencies (`npm ci`)
- `make fmt` / `make lint` / `make typecheck` — format, lint, and type-check
- `make test` — run Vitest unit tests
- `make build` — compile TypeScript to `dist/` and build `app:local` image
- `make acceptance` — start `compose.yaml`, run Playwright API tests, and tear down
- `make smoke URL=<url>` — run `@prod-safe` Playwright API checks against `URL`
