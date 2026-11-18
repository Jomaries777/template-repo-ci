# Node Stack (TypeScript + `node:http`)

Minimal Node 22 HTTP service with zero runtime framework dependencies.

## Endpoints

- `GET /` — returns `200 {"message":"hello"}`
- `GET /health` — returns `200 {"status":"ok","version":"<APP_VERSION|dev>"}`. Not `/healthz`: Cloud Run reserves some paths ending in `z`, so keep new routes off them too
- Any other path or method — returns `404 {"error":"not found"}`

## Make Targets

- `make install` — install locked dependencies (`npm ci`)
- `make fmt` / `make lint` / `make typecheck` — format, lint, and type-check
- `make test` — run Vitest unit tests
- `make build` — compile TypeScript to `dist/` and build `app:local` image
- `make acceptance` — start `compose.yaml`, run Playwright API tests, and tear down
- `make smoke URL=<url>` — run `@prod-safe` Playwright API checks against `URL`

## Dependencies

- Change `package-lock.json` only through npm 11 (`npx -y npm@11 install …`). npm 10.9 drops the `libc` fields of the optional native packages, so npm could then pick the wrong binary on musl hosts.
- Dependabot keeps them current (`dependabot-updates.yml`, which bootstrap appends to `.github/dependabot.yml`): patch updates are approved by the bot and auto-merge; minor and major updates wait for the owner.
