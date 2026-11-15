#!/usr/bin/env bash
# Tests for scripts/agy-events.sh against the real Spike A fixtures.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
events="$root/scripts/agy-events.sh"
fx="$root/tests/fixtures/agy"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # name jq-expr file
  if jq -e "$2" "$3" >/dev/null 2>&1; then
    echo "ok - $1"
  else
    echo "not ok - $1"
    fail=1
  fi
}

for m in plain boost teamwork; do
  "$events" <"$fx/$m.ndjson" >"$tmp/$m.json"
done

check "plain: SUCCESS" '.status == "SUCCESS"' "$tmp/plain.json"
check "plain: >=1 file written" '(.files_written | length) >= 1' "$tmp/plain.json"
check "boost: SUCCESS" '.status == "SUCCESS"' "$tmp/boost.json"
check "boost: 2 files written" '(.files_written | length) == 2' "$tmp/boost.json"
check "boost: files are workspace-relative" '.files_written == ["add.py","test_add.py"]' "$tmp/boost.json"
check "boost: tokens recorded" '.total_tokens > 0' "$tmp/boost.json"
check "teamwork: SUCCESS" '.status == "SUCCESS"' "$tmp/teamwork.json"
check "teamwork: delegations >= 1" '.delegations >= 1' "$tmp/teamwork.json"
check "teamwork: 0 files in workspace" '(.files_written | length) == 0' "$tmp/teamwork.json"
check "teamwork: delegated_without_changes_risk" '.delegated_without_changes_risk == true' "$tmp/teamwork.json"
check "boost: no risk flag" '.delegated_without_changes_risk == false' "$tmp/boost.json"

# Throttle callback invoked with AGY_THROTTLE_SECONDS=0.
cat >"$tmp/cb.sh" <<EOF
#!/usr/bin/env bash
echo called >>"$tmp/cb.count"
cp "\$1" "$tmp/cb.last"
EOF
chmod +x "$tmp/cb.sh"
AGY_ON_PROGRESS="$tmp/cb.sh" AGY_THROTTLE_SECONDS=0 "$events" <"$fx/boost.ndjson" >/dev/null
if [[ -s "$tmp/cb.count" && -s "$tmp/cb.last" ]]; then
  echo "ok - progress callback invoked"
else
  echo "not ok - progress callback invoked"
  fail=1
fi

# Throttling: with a large interval only the terminal callbacks fire.
rm -f "$tmp/cb.count"
AGY_ON_PROGRESS="$tmp/cb.sh" AGY_THROTTLE_SECONDS=3600 "$events" <"$fx/boost.ndjson" >/dev/null
if [[ "$(wc -l <"$tmp/cb.count" | tr -d ' ')" -le 2 ]]; then
  echo "ok - progress callback throttled"
else
  echo "not ok - progress callback throttled"
  fail=1
fi

# Privacy: summaries never contain text_delta content.
if grep -q "Solo Routine" "$tmp/cb.last"; then
  echo "not ok - summary leaks text_delta"
  fail=1
else
  echo "ok - summary omits text_delta content"
fi

# Malformed / unknown lines tolerated; AGY_SUMMARY_JSON honoured.
{
  echo 'this is not json'
  echo '{"event":"mystery","x":1}'
  echo '{"event":"step_update","step_update":{"step_index":1,'
  cat "$fx/plain.ndjson"
} | AGY_SUMMARY_JSON="$tmp/mal.json" "$events"
check "malformed line tolerated" '.status == "SUCCESS" and (.files_written | length) >= 1' "$tmp/mal.json"

# Empty input.
: | AGY_SUMMARY_JSON="$tmp/empty.json" "$events"
check "empty stream -> NO_RESULT" '.status == "NO_RESULT"' "$tmp/empty.json"

exit "$fail"
