#!/usr/bin/env bash
# Real (non-dry-run) tests for verify_gate and agy-report.sh check-run
# selection, using temp git repos and stubbed gh/make on PATH. No network.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
contains() { # name text pattern
  if grep -Eq -- "$3" <<<"$2"; then ok "$1"; else nok "$1 (got: $2)"; fi
}
lacks() {
  if grep -Eq -- "$3" <<<"$2"; then nok "$1 (got: $2)"; else ok "$1"; fi
}

# --- stubs on PATH -----------------------------------------------------------
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/make" <<'EOF'
#!/usr/bin/env bash
# Stub make: records the Makefile it saw, exits with $STUB_MAKE_RC.
dir="."
[[ "${1:-}" == "-C" ]] && dir="$2"
cp "$dir/Makefile" "$STUB_DIR/make.saw" 2>/dev/null || true
exit "${STUB_MAKE_RC:-0}"
EOF
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh: logs argv and returns canned JSON from $STUB_DIR.
echo "$*" >>"$STUB_DIR/gh.log"
[[ -z "${GH_TOKEN:-}" ]] && echo "NO_TOKEN" >>"$STUB_DIR/gh.log"
case "$*" in
  "pr list"*) cat "$STUB_DIR/pr.json" ;;
  *"/pulls/"*"/commits"*) cat "$STUB_DIR/commits.txt" 2>/dev/null || true ;;
  *"/commits/"*"/check-runs"*)
    all="$*"
    sha="${all#*commits/}"
    sha="${sha%%/*}"
    cat "$STUB_DIR/checks_$sha.json" 2>/dev/null || true
    ;;
  *"-X POST"*"check-runs"*) echo 999 ;;
esac
exit 0
EOF
cat >"$stubs/bot-token.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub-token"
EOF
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"
export STUB_DIR="$tmp/stub-state"
export AGY_TEST_MODE=1
export AGY_GATE_PASS_ENV="STUB_DIR STUB_MAKE_RC"
mkdir -p "$STUB_DIR"
export BOT_TOKEN_SCRIPT="$stubs/bot-token.sh"
export BOT_APP_ID=123
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- fixture repo: bare origin + clone on a feature branch -------------------
new_repo() { # dir
  local d="$1"
  rm -rf "$d" "$d.git"
  git init -q --bare "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  (
    cd "$d"
    git checkout -q -b main
    mkdir -p tests/scripts scripts src
    echo 'lint:' >Makefile
    echo 'echo origin' >tests/scripts/test_x.sh
    echo hi >src/a.txt
    git add -A
    git commit -q -m init
    git push -q origin main
    git checkout -q -b agy/feature
  )
}

# shellcheck source=scripts/agy-run.sh
source "$root/scripts/agy-run.sh"
export STUB_MAKE_RC=0

repo="$tmp/r1"
new_repo "$repo"

gate() { # -> GATE_REASONS
  ALLOW_PROTECTED="${1:-0}"
  verify_gate "$repo" SUCCESS
}

gate
contains "gate: empty diff fails" "$GATE_REASONS" 'no changes'

mkdir -p "$repo/.github/workflows"
echo x >"$repo/.github/workflows/ci.yml"
gate 1
contains "gate: workflows path fails even with --allow-protected" "$GATE_REASONS" 'workflows'
rm -rf "$repo/.github"

echo y >"$repo/scripts/new.sh"
gate
contains "gate: protected path fails without flag" "$GATE_REASONS" 'protected harness paths.*scripts/new.sh'
gate 1
if [[ -z "$GATE_REASONS" ]]; then ok "gate: protected path passes with --allow-protected"; else nok "gate: protected path with flag (got: $GATE_REASONS)"; fi
rm -f "$repo/scripts/new.sh"

echo m >>"$repo/Makefile"
gate
contains "gate: Makefile change is protected" "$GATE_REASONS" 'protected harness paths.*Makefile'
gate 1
saw="$(cat "$STUB_DIR/make.saw")"
if [[ "$saw" == "lint:" ]]; then ok "gate: make ran with origin/main Makefile"; else nok "gate: make saw modified Makefile"; fi
if [[ "$(cat "$repo/Makefile")" == $'lint:\nm' ]]; then ok "gate: agent Makefile restored afterwards"; else nok "gate: agent Makefile not restored"; fi
git -C "$repo" checkout -q -- Makefile

echo new >"$repo/src/b.txt"
STUB_MAKE_RC=1 gate
contains "gate: failing make fails" "$GATE_REASONS" 'make lint test failed'

gate
if [[ -z "$GATE_REASONS" ]]; then ok "gate: good change passes"; else nok "gate: good change (got: $GATE_REASONS)"; fi

agy_reason="$(verify_gate "$repo" ERROR; echo "$GATE_REASONS")"
contains "gate: non-SUCCESS agy status fails" "$agy_reason" "not SUCCESS"

git -C "$repo" checkout -q --detach
gate
contains "gate: detached HEAD refused" "$GATE_REASONS" 'detached HEAD'
git -C "$repo" checkout -q agy/feature

# --- agy-report.sh with stubbed gh -------------------------------------------
report="$root/scripts/agy-report.sh"

git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: change"
head="$(git -C "$repo" rev-parse HEAD)"
old="$(git -C "$repo" rev-parse HEAD~1)"
printf '{"number":7,"headRefOid":"%s"}\n' "$head" >"$STUB_DIR/pr.json"
export AGY_PUSH_URL="$tmp/r1.git"

# existing run on head -> reused, no new run created
printf '{"id":55,"name":"antigravity/teamwork","head_sha":"%s","output":{"summary":"- earlier"}}\n' "$head" >"$STUB_DIR/checks_$head.json"
(cd "$repo" && "$report" progress "working" --repo o/r) >/dev/null
log="$(cat "$STUB_DIR/gh.log")"
contains "report: reuses existing run (PATCH 55)" "$log" 'PATCH repos/o/r/check-runs/55'
lacks "report: no new run when one exists" "$log" 'POST repos/o/r/check-runs'
lacks "report: token passed inline to gh" "$log" 'NO_TOKEN'
lacks "report: token not exported to shell" "$(env)" 'stub-token'

# none anywhere -> creates antigravity/interactive on head
rm -f "$STUB_DIR"/checks_* "$STUB_DIR/gh.log"
: >"$STUB_DIR/commits.txt"
(cd "$repo" && "$report" start "go" --repo o/r) >/dev/null
log="$(cat "$STUB_DIR/gh.log")"
contains "report: creates antigravity/interactive when none" "$log" 'POST.*name=antigravity/interactive.*head_sha='"$head"

# run only on an older commit -> found there, not duplicated
rm -f "$STUB_DIR/gh.log"
printf '{"id":77,"name":"antigravity/swarm","head_sha":"%s","output":{"summary":"- s"}}\n' "$old" >"$STUB_DIR/checks_$old.json"
printf '%s\n%s\n' "$head" "$old" >"$STUB_DIR/commits.txt"
(cd "$repo" && "$report" progress "x" --repo o/r) >/dev/null
log="$(cat "$STUB_DIR/gh.log")"
contains "report: finds run on older PR commit" "$log" 'PATCH repos/o/r/check-runs/77'
lacks "report: no duplicate interactive run" "$log" 'POST repos/o/r/check-runs'

# done -> final run on the (new) head SHA, old run neutral
rm -f "$STUB_DIR/gh.log"
(cd "$repo" && "$report" "done" "finished" --repo o/r) >/dev/null 2>&1
log="$(cat "$STUB_DIR/gh.log")"
final="$(git -C "$repo" rev-parse HEAD)"
contains "report done: final run created on head SHA" "$log" "POST repos/o/r/check-runs.*name=antigravity/swarm.*head_sha=$final.*conclusion=success"
contains "report done: old run marked neutral" "$log" 'PATCH repos/o/r/check-runs/77.*conclusion=neutral'
contains "report done: PR marked ready" "$log" 'pr ready 7'

# done with a failing gate -> failure run + comment, non-zero exit
rm -f "$STUB_DIR/gh.log"
if (cd "$repo" && STUB_MAKE_RC=1 "$report" "done" "finished" --repo o/r) >/dev/null 2>&1; then
  nok "report done: failing gate exits non-zero"
else
  ok "report done: failing gate exits non-zero"
fi
log="$(cat "$STUB_DIR/gh.log")"
contains "report done (fail): failure conclusion" "$log" 'conclusion=failure'
contains "report done (fail): PR comment" "$log" 'pr comment 7'

# --allow-protected is refused by agy-report (the interactive agent runs it)
if (cd "$repo" && "$report" "done" "x" --repo o/r --allow-protected) >/dev/null 2>&1; then
  nok "report: --allow-protected refused"
else
  ok "report: --allow-protected refused"
fi

# commit_and_push refuses secret-looking untracked files
echo 'SECRET=1' >"$repo/.env"
if (commit_and_push o/r "$repo" agy/feature "chore: leftovers") >/dev/null 2>&1; then
  nok "commit: .env refused"
else
  ok "commit: .env refused"
fi
if git -C "$repo" diff --cached --name-only | grep -q '^\.env$'; then nok "commit: .env left unstaged"; else ok "commit: .env left unstaged"; fi
rm -f "$repo/.env"

# detached HEAD refused by agy-report
git -C "$repo" checkout -q --detach
if (cd "$repo" && "$report" start "x" --repo o/r) >/dev/null 2>&1; then
  nok "report: detached HEAD refused"
else
  ok "report: detached HEAD refused"
fi

exit "$fail"
