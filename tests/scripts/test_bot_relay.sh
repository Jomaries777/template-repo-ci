#!/usr/bin/env bash
# Tests for scripts/bot-relay.sh (spec 0002 FR-6). Real git with a local bare
# "origin"; a fake curl records the payload and plays the bot by committing
# the work tree onto the payload's parent and pushing it, the way the broker
# would. Run from the repo root.
set -euo pipefail

src="$PWD"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ok - skipped (needs jq)"
  exit 0
fi

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch main

# origin: owner/name are the last two parts of its path.
mkdir -p "$tmp/Jomaries777"
git init -q --bare "$tmp/Jomaries777/sandbox.git"
git clone -q "$tmp/Jomaries777/sandbox.git" "$tmp/seed" 2>/dev/null
(cd "$tmp/seed" && printf 'old\n' >old.txt && printf 'keep\n' >keep.txt && git add . && git commit -qm init && git push -q origin main)

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl for bot-relay.sh: record, then act as the broker.
printf '%s\n' "$*" >>"$CURL_ARGS"
prev=""
for a in "$@"; do
  if [[ "$prev" == -H && "$a" == @* ]]; then cat "${a#@}" >>"$CURL_HDRS"; fi
  if [[ "$prev" == -H && "$a" != @* ]]; then printf '%s\n' "$a" >>"$CURL_HDRS"; fi
  if [[ "$prev" == --data && "$a" == @* ]]; then cp "${a#@}" "$CURL_PAYLOAD"; fi
  prev="$a"
done
if [[ -n "${FAKE_CODE:-}" ]]; then
  printf '%s\n%s' "${FAKE_BODY:-{\}}" "$FAKE_CODE"
  exit 0
fi
parent="$(jq -r .parent "$CURL_PAYLOAD")"
branch="$(jq -r .branch "$CURL_PAYLOAD")"
msg="$(jq -r .message "$CURL_PAYLOAD")"
sha="$(GIT_AUTHOR_NAME=bot GIT_COMMITTER_NAME=bot git commit-tree "HEAD^{tree}" -p "$parent" -m "$msg")"
git push -q origin "$sha:refs/heads/$branch"
printf '{"commit":"%s","branch":"%s","pr_url":"https://github.test/pull/1"}\n200' "$sha" "$branch"
EOF
chmod +x "$tmp/bin/curl"

# work: a fresh clone on a branch, with BOT_* config in its own dir.
n=0
new_work() {
  n=$((n + 1))
  rm -rf "$tmp/work" "$tmp/cfg"
  git clone -q "$tmp/Jomaries777/sandbox.git" "$tmp/work"
  mkdir -p "$tmp/cfg"
  git -C "$tmp/work" checkout -qb "${1:-test/relay-$n}"
}
# relay [args...]: run bot-relay.sh in work; sets out, err, rc.
relay() {
  rm -f "$tmp/args" "$tmp/hdrs" "$tmp/payload"
  rc=0
  out="$(cd "$tmp/work" && PATH="$tmp/bin:$PATH" CURL_ARGS="$tmp/args" CURL_HDRS="$tmp/hdrs" \
    CURL_PAYLOAD="$tmp/payload" BOT_CONFIG_DIR="$tmp/cfg" BOT_BROKER_URL="${URL-https://broker.test}" \
    bash "$src/scripts/bot-relay.sh" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
payload() { jq -r "$1" "$tmp/payload"; }

# 1. A new branch: files, modes, deletes and parent, then a clean resync.
new_work
cd "$tmp/work"
printf 'hello\n' >a.txt
printf '#!/bin/sh\necho hi\n' >run.sh && chmod +x run.sh
printf '\x89PNG\xff\xfe' >dot.png
git rm -q old.txt
git add . && git commit -qm "feat: add things"
main_sha="$(git rev-parse origin/main)"
cd "$src"
relay --pr "test: relay" --pr-body "body"
if [[ $rc == 0 ]]; then pass "new branch: relayed"; else fail "new branch: relayed (rc $rc, err: $err)"; fi
if grep -q "https://broker.test/relay/$" "$tmp/args"; then pass "posts to /relay/ (matches a /relay path-limited secret)"; else fail "posts to /relay/ ($(cat "$tmp/args"))"; fi
if [[ "$(payload .parent)" == "$main_sha" ]]; then pass "new branch: parent is origin/main"; else fail "new branch: parent is origin/main"; fi
if [[ "$(payload .repo)" == "Jomaries777/sandbox" ]]; then pass "repo from the origin URL"; else fail "repo from the origin URL ($(payload .repo))"; fi
if [[ "$(payload .message)" == "feat: add things" ]]; then pass "message from the one commit"; else fail "message from the one commit"; fi
if [[ "$(payload '.pr.title') $(payload '.pr.body')" == "test: relay body" ]]; then pass "PR title and body"; else fail "PR title and body"; fi
if [[ "$(payload '[.files[].path] | sort | join(",")')" == "a.txt,dot.png,old.txt,run.sh" ]]; then pass "changed files only"; else fail "changed files only ($(payload '[.files[].path]|join(",")'))"; fi
if [[ "$(payload '.files[] | select(.path=="old.txt") | .delete')" == true ]]; then pass "delete entry"; else fail "delete entry"; fi
if [[ "$(payload '.files[] | select(.path=="run.sh") | .mode')" == 100755 ]]; then pass "executable mode kept"; else fail "executable mode kept"; fi
if [[ "$(payload '.files[] | select(.path=="dot.png") | .content_b64' | base64 -d | od -An -tx1 | tr -d ' \n')" == 89504e47fffe ]]; then
  pass "binary content intact"
else
  fail "binary content intact"
fi
if [[ "$(payload '.files[] | select(.path=="a.txt") | .content_b64' | base64 -d)" == hello ]]; then pass "text content intact"; else fail "text content intact"; fi
if [[ "$(git -C "$tmp/work" rev-parse HEAD)" == "$(git -C "$tmp/work" rev-parse origin/test/relay-1)" ]] &&
  git -C "$tmp/work" diff --cached --quiet && [[ -z "$(git -C "$tmp/work" status --porcelain)" ]]; then
  pass "resynced onto the bot's commit, clean"
else
  fail "resynced onto the bot's commit, clean ($err)"
fi
if grep -q "https://github.test/pull/1" <<<"$out"; then pass "prints the PR"; else fail "prints the PR ($out)"; fi
if ! grep -qi authorization "$tmp/hdrs"; then pass "no identity file: no Authorization header (the proxy adds it)"; else fail "no identity file: no Authorization header"; fi

# 2. The next relay on the same branch: parent is the bot's commit, only the new change.
bot_sha="$(git -C "$tmp/work" rev-parse HEAD)"
(cd "$tmp/work" && printf 'more\n' >b.txt && git add b.txt && git commit -qm "feat: more")
relay
if [[ $rc == 0 && "$(payload .parent)" == "$bot_sha" && "$(payload '[.files[].path]|join(",")')" == b.txt ]]; then pass "existing branch: parent is the bot head, one file"; else fail "existing branch (rc $rc, err: $err)"; fi

# 2b. Non-ASCII, spaces and glob characters in names arrive unquoted.
(cd "$tmp/work" && printf 'c\n' >"café menu [v1].txt" && git add . && git commit -qm "feat: menu")
relay
if [[ $rc == 0 && "$(payload '.files[0].path')" == "café menu [v1].txt" && "$(payload '.files[0].content_b64' | base64 -d)" == c ]]; then
  pass "non-ASCII path sent as is"
else
  fail "non-ASCII path sent as is (rc $rc, err: $err, path $(payload '.files[0].path'))"
fi

# 3. Identity on a signed-in device goes in a header file, never in the args.
ident="$(printf 'ident-%s' "$RANDOM$RANDOM")"
printf '%s\n' "$ident" >"$tmp/cfg/identity"
(cd "$tmp/work" && printf 'x\n' >c.txt && git add c.txt && git commit -qm "feat: c")
relay
if [[ $rc == 0 ]] && grep -q "Authorization: Bearer $ident" "$tmp/hdrs" && ! grep -q "$ident" "$tmp/args" && ! grep -q "$ident" <<<"$out$err"; then
  pass "identity sent in a header, not in args or output"
else
  fail "identity sent in a header, not in args or output (rc $rc)"
fi
rm -f "$tmp/cfg/identity"

# 4. Refusals before anything is sent.
refused() { # refused <name> <expected stderr pattern>
  if [[ $rc != 0 && ! -s "$tmp/payload" ]] && grep -q "$2" <<<"$err"; then pass "refused: $1"; else fail "refused: $1 (rc $rc, err: $err)"; fi
}
new_work
(cd "$tmp/work" && printf 'x\n' >d.txt && git add d.txt && git commit -qm "feat: d" && printf 'y\n' >dirty.txt)
relay
refused "uncommitted changes" "commit or stash"
new_work wip
(cd "$tmp/work" && printf 'x\n' >d.txt && git add d.txt && git commit -qm "feat: d")
relay
refused "branch name" "can't be relayed"
new_work
(cd "$tmp/work" && mkdir -p .github/workflows && printf 'on: push\n' >.github/workflows/x.yml && git add . && git commit -qm "ci: x")
relay
refused "workflow file" "workflows"
new_work
(cd "$tmp/work" && printf '1\n' >e.txt && git add e.txt && git commit -qm one && printf '2\n' >f.txt && git add f.txt && git commit -qm two)
relay
refused "several commits without -m" "give its message with -m"
relay -m "feat: e and f"
if [[ $rc == 0 && "$(payload .message)" == "feat: e and f" ]]; then pass "several commits with -m"; else fail "several commits with -m (rc $rc, err: $err)"; fi
new_work
(cd "$tmp/work" && printf 'x\n' >g.txt && git add g.txt && git commit -qm "feat: g")
(cd "$tmp/seed" && git pull -q && printf 'new\n' >main2.txt && git add main2.txt && git commit -qm main2 && git push -q origin main)
relay
refused "behind origin/main" "rebase on it first"
URL="" relay
refused "no broker URL" "no broker URL"
URL="http://broker.test" relay
refused "plain http broker" "must be https"

# 5. A broker error names the code and a hint.
new_work
(cd "$tmp/work" && git pull -q origin main && printf 'x\n' >h.txt && git add h.txt && git commit -qm "feat: h")
FAKE_CODE=409 FAKE_BODY='{"error":"stale_parent"}' relay
if [[ $rc != 0 ]] && grep -q "stale_parent (HTTP 409); the branch moved" <<<"$err"; then
  pass "broker error: code and hint"
else
  fail "broker error: code and hint (rc $rc, err: $err)"
fi
if [[ "$(git -C "$tmp/work" log -1 --format=%s)" == "feat: h" ]]; then pass "broker error: local branch untouched"; else fail "broker error: local branch untouched"; fi

exit $((failures > 0))
