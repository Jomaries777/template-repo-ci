# M3 step 6: python and go live runs (GitHub Pages, 2026-11-26)

Run on 2026-11-26 in two public throwaway repos, both created from the template and bootstrapped straight onto `github-pages`:
- [`Jomaries777/sandbox-python-static`](https://github.com/Jomaries777/sandbox-python-static), with the python stack;
- [`Jomaries777/sandbox-go-static`](https://github.com/Jomaries777/sandbox-go-static), with the go stack.

This closes plan.md M3 step 6: "python and go each get one live run to github-pages in a throwaway repo (criterion 1)". The run is bootstrap plus its first deploy. The Pages adapter's full chain and revert were already proven with node in `sandbox-node-workers`.

The steps were split:
- **Claude Code** created both repos (`gh repo create --template … --public --clone`) and ran `scripts/bootstrap.sh --stack <stack> --target github-pages --dry-run` in each clone.
- **The owner**, from their Mac:
  - ran `make bootstrap STACK=<stack> TARGET=github-pages` in each clone;
  - installed the bot App on both repos;
  - approved `production`.
- **Claude Code** then ran `make doctor` and read the deploy runs.

Every time below comes from a log timestamp (UTC).

## Results

| Spec §8 criterion | Sandbox evidence | Result |
|---|---|---|
| 1 Bootstrap with no UI steps (python, github-pages) | One pass, see Setup. Deploy run [45816232714](https://github.com/Jomaries777/sandbox-python-static/actions/runs/45816232714) released `1d07579` | ✅ |
| 1 Bootstrap with no UI steps (go, github-pages) | One pass, see Setup. Deploy run [45816390784](https://github.com/Jomaries777/sandbox-go-static/actions/runs/45816390784) released `feb9db0` | ✅ |

## Setup

- **Dry run:** exited 0 in both clones and left them clean.
  - Every remote call named only the clone's own repo, and no other repo appeared in the output.
  - The steps were: the Claude token from the Keychain, `bot-secrets.sh` through the broker, `git push origin HEAD:main`, the settings and the ruleset.
- **Bootstrap:** each ran in one pass, with no prompt.
  - **GitHub:** the Environments; the `CLAUDE_CODE_OAUTH_TOKEN` secret and its `_SET_AT` variable; `BOT_APP_PRIVATE_KEY` for `actions` and `dependabot` (set by the broker); `BOT_APP_ID`; then the push to `main`, the repo settings and the `main` ruleset.
  - **The Pages step:** it created `gh-pages`, and GitHub turned Pages on for the new branch. The python run printed "Pages already enabled", the go run "Pages already enabled (by GitHub, for the new gh-pages branch)". Neither hit the 2026-11-18 HTTP 409 (template #45).
- **The only browser steps:** installing the bot App on each repo and approving `production`. The spec leaves both to the owner.
- **Doctor:** `make doctor` ended with "doctor: all checks passed" in both clones.

## Deploys

**python, run 45816232714:**
- **Jobs:** `classify` and `artifact` passed, and `dev` was skipped: Pages has production only.
- **Baseline:** failed twice, with the 10 s retry in between ("2 failed, 1 deselected"). Pages was serving bootstrap's `gh-pages` commit `5109224`, which has no export. "Not healthy before this release" is expected on a first deploy, and the release went on.
- **Pre-traffic:** the test against the local preview passed ("2 passed, 1 deselected"). The deselected test isn't `prod_safe`.
- **Promote:** `1d07579` became `gh-pages` commit `ef0328b`, live 43.3 s after promote started (12:25:57.64 → 12:26:40.98).
- **Live checks:** 3 of 3 on `https://jomaries777.github.io/sandbox-python-static`, 60 s apart.
- **Afterwards:** `released 1d07579…`. `GET /health/` returns `{"status": "ok", "version": "1d075796…"}`.

**go, run 45816390784:**
- **Jobs:** `classify` and `artifact` passed, and `dev` was skipped.
- **Baseline:** failed twice (`TestProdSafeHealthReturnsOK` and `TestProdSafeRootReturnsHello` against bootstrap's `gh-pages` commit `50b75f2`), with the same "not healthy before this release".
- **Pre-traffic:** `go test` reported `ok` against the local preview.
- **Promote:** `feb9db0` became `gh-pages` commit `a11f780`, live 37.3 s after promote started (12:26:18.88 → 12:26:56.16).
- **Live checks:** 3 of 3 (`ok`) on `https://jomaries777.github.io/sandbox-go-static`, 60 s apart.
- **Afterwards:** `released feb9db0…`. `GET /health/` returns `{"status":"ok","version":"feb9db01…"}`.

## Findings

1. **Creating a repo from the template starts a deploy run that does nothing.** The template's own commit (`Initial commit`) triggered `deploy.yml` in both new repos, before bootstrap ran: runs 45815986990 and 45816013773. `classify` passed and every other job was skipped. It is harmless, but it is the first entry in each new project's Actions list. Fixed on 2026-11-27: `classify` is skipped when the push creates `main`, so that run does no work (#92).
2. **`/health` on Pages answers 301 to `/health/`.** The export writes each route as `<route>/index.html`, so Pages redirects the bare path. The smoke suites follow the redirect and pass in all three stacks. A client that doesn't follow redirects gets the 301. This was already true for node: `sandbox-node-static`'s `/health` returns the same 301. It is first written down here. No fix.

## Timings

| Step | python | go |
|---|---|---|
| Repo created → bootstrap's deploy run created | 12:02:30 → 12:04:17 | 12:02:42 → 12:05:18 |
| Promote → `gh-pages` commit live (includes the Pages build) | 43.3 s | 37.3 s |
| Production job, start to end (it starts on the owner's approval) | 3 min 27 s | 3 min 34 s |
