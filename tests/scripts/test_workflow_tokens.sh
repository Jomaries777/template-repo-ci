#!/usr/bin/env bash
# Workflow token table, review cap and Dependabot auto-merge checks
# (spec 0003: FR-6, FR-8, token permissions table, C2, C7; S1/C3 fallback).
#
# Uses bash, grep, awk, sed and jq only. Prints TAP-style lines and exits
# non-zero if any case fails. Override WORKFLOWS_DIR to test fixture files.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflows="${WORKFLOWS_DIR:-$root/.github/workflows}"

PINNED_APP_TOKEN_ACTION="actions/create-github-app-token@f418cff399f7aef4c2f0ad47e25ca7a6abbdd6fc"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

if ! command -v jq >/dev/null 2>&1; then
  fail "prerequisite: jq is installed"
  exit 1
fi

# --- YAML helpers (awk + sed, POSIX/BSD/GNU/mawk portable) -------------------

# clean_scalar <raw>: strip unquoted trailing comment, whitespace, outer quotes.
clean_scalar() {
  awk '
    function clean(s,   rest, q, out, i, c, n) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (substr(s, 1, 1) == "\"") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) {
            i++
            out = out substr(rest, i, 1)
          } else if (c == "\"") {
            if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
            break
          } else {
            out = out c
          }
        }
      } else if (substr(s, 1, 1) == "\047") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\047") {
            if (i < n && substr(rest, i + 1, 1) == "\047") {
              out = out "\047"
              i++
            } else {
              if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
              break
            }
          } else {
            out = out c
          }
        }
      }
      sub(/[ \t]+#.*$/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    { print clean($0) }
  ' <<<"$1"
}

# is_gha_expr <value> <expected_inner>: true if value is ${{ <expected_inner> }}.
is_gha_expr() {
  local val="$1" want="$2"
  local re='^\$[{][{][[:space:]]*(.*[^[:space:]])[[:space:]]*[}][}]$'
  [[ "$val" =~ $re ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "$want" ]]
}

# extract_top_scalar <file> <key>: value of a column-0 key (e.g. `name: pr`).
extract_top_scalar() {
  local file="$1" key="$2" raw
  raw="$(awk -v k="$key" '
    $0 ~ ("^" k ":([ \t]|$)") {
      sub("^" k ":[ \t]*", "")
      print
      exit
    }
  ' "$file")"
  clean_scalar "$raw"
}

# extract_top_section <file> <key>: prints body lines under a column-0 key.
extract_top_section() {
  local file="$1" key="$2"
  awk -v k="$key" '
    !in_sec {
      if ($0 ~ ("^" k ":[ \t]*(#.*)?$")) {
        in_sec = 1
      }
      next
    }
    /^[ \t]*$/ || /^[ \t]*#/ { print; next }
    /^[^ \t]/ { exit }
    { print }
  ' "$file"
}

# list_jobs <file>: prints job keys under `jobs:`, one per line.
list_jobs() {
  local file="$1"
  extract_top_section "$file" jobs | awk '
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (job_ind == "") job_ind = ind
      if (ind == job_ind && $0 ~ /^[ \t]*[A-Za-z0-9_-]+:[ \t]*(#.*)?$/) {
        s = $0
        sub(/^[ \t]*/, "", s)
        sub(/:.*$/, "", s)
        print s
      }
    }
  '
}

# extract_job <file> <job_name>: prints the body of one job under `jobs:`.
extract_job() {
  local file="$1" job="$2"
  extract_top_section "$file" jobs | awk -v target="$job" '
    /^[ \t]*$/ || /^[ \t]*#/ {
      if (in_job) print
      next
    }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (job_ind == "") job_ind = ind
      if (!in_job) {
        if (ind == job_ind && $0 ~ ("^[ \t]*" target ":[ \t]*(#.*)?$")) {
          in_job = 1
        }
        next
      }
      if (ind <= job_ind) exit
      print
    }
  '
}

# extract_mapping_from_block <block_text> <key>:
# Extracts direct child key=value pairs of `<key>:` (e.g. `env:`, `with:`, `permissions:`)
# inside a job or step block, skipping deeper lines (multiline scalars).
extract_mapping_from_block() {
  local block="$1" key="$2"
  awk -v target="$key" '
    function clean(s,   rest, out, i, c, n) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (substr(s, 1, 1) == "\"") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { i++; out = out substr(rest, i, 1) }
          else if (c == "\"") {
            if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
            break
          } else { out = out c }
        }
      } else if (substr(s, 1, 1) == "\047") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\047") {
            if (i < n && substr(rest, i + 1, 1) == "\047") { out = out "\047"; i++ }
            else {
              if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
              break
            }
          } else { out = out c }
        }
      }
      sub(/[ \t]+#.*$/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (base_ind == "") base_ind = ind
      if (!in_map) {
        if (ind == base_ind && $0 ~ ("^[ \t]*" target ":[ \t]*(#.*)?$")) {
          in_map = 1
          map_ind = ind
        }
        next
      }
      if (ind <= map_ind) exit
      if (child_ind == "") child_ind = ind
      if (ind == child_ind && $0 ~ /^[ \t]*[A-Za-z0-9_.-]+:([ \t]|$)/) {
        line = substr($0, ind + 1)
        c = index(line, ":")
        k = substr(line, 1, c - 1)
        v = clean(substr(line, c + 1))
        print k "=" v
      }
    }
  ' <<<"$block"
}

# extract_top_mapping <file> <key>: direct child key=value pairs of a col-0 mapping.
extract_top_mapping() {
  local file="$1" key="$2"
  extract_top_section "$file" "$key" | awk '
    function clean(s,   rest, out, i, c, n) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (substr(s, 1, 1) == "\"") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { i++; out = out substr(rest, i, 1) }
          else if (c == "\"") {
            if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
            break
          } else { out = out c }
        }
      } else if (substr(s, 1, 1) == "\047") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\047") {
            if (i < n && substr(rest, i + 1, 1) == "\047") { out = out "\047"; i++ }
            else {
              if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
              break
            }
          } else { out = out c }
        }
      }
      sub(/[ \t]+#.*$/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (child_ind == "") child_ind = ind
      if (ind == child_ind && $0 ~ /^[ \t]*[A-Za-z0-9_.-]+:([ \t]|$)/) {
        line = substr($0, ind + 1)
        c = index(line, ":")
        k = substr(line, 1, c - 1)
        v = clean(substr(line, c + 1))
        print k "=" v
      }
    }
  '
}

# extract_scalar_or_block_field <block_text> <key>:
# Extracts a field (`if`, `id`, `uses`, `name`, `permissions`) from a job or step block.
# Supports single-line scalars, multiline block scalars (`>-`, `>`, `|`, `|-`),
# and multiline plain scalars (indented continuation lines).
extract_scalar_or_block_field() {
  local block="$1" key="$2"
  awk -v target="$key" '
    function clean(s,   rest, out, i, c, n) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (substr(s, 1, 1) == "\"") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { i++; out = out substr(rest, i, 1) }
          else if (c == "\"") {
            if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
            break
          } else { out = out c }
        }
      } else if (substr(s, 1, 1) == "\047") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\047") {
            if (i < n && substr(rest, i + 1, 1) == "\047") { out = out "\047"; i++ }
            else {
              if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
              break
            }
          } else { out = out c }
        }
      }
      sub(/[ \t]+#.*$/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    {
      if (in_block || in_plain) {
        if ($0 ~ /^[ \t]*$/) next
        if (in_plain && $0 ~ /^[ \t]*#/) next
        match($0, /^[ \t]*/)
        ind = RLENGTH
        if (ind <= field_ind) exit
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        if (in_plain) sub(/[ \t]+#.*$/, "", line)
        out = (out == "" ? line : out " " line)
        next
      }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (base_ind == "") base_ind = ind
      if (ind == base_ind && $0 ~ ("^[ \t]*" target ":([ \t]|$)")) {
        field_ind = ind
        val = substr($0, ind + length(target) + 2)
        raw = clean(val)
        if (raw ~ /^[>|]([+-]?[1-9]?|[1-9]?[+-]?)$/) {
          in_block = 1
          next
        }
        # Allow multiline plain scalar continuations (e.g. `if:\n  expr` or wrapped `if:`)
        in_plain = 1
        out = raw
        next
      }
    }
    END {
      if (in_block || in_plain) print out
    }
  ' <<<"$block"
}

# extract_run_body <step_block>: extracts the `run:` script body, dedented.
extract_run_body() {
  local block="$1"
  awk '
    function clean(s,   rest, out, i, c, n) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (substr(s, 1, 1) == "\"") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { i++; out = out substr(rest, i, 1) }
          else if (c == "\"") {
            if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
            break
          } else { out = out c }
        }
      } else if (substr(s, 1, 1) == "\047") {
        rest = substr(s, 2)
        n = length(rest)
        out = ""
        for (i = 1; i <= n; i++) {
          c = substr(rest, i, 1)
          if (c == "\047") {
            if (i < n && substr(rest, i + 1, 1) == "\047") { out = out "\047"; i++ }
            else {
              if (substr(rest, i + 1) ~ /^[ \t]*(#.*)?$/) return out
              break
            }
          } else { out = out c }
        }
      }
      return s
    }
    {
      if (in_run) {
        if ($0 ~ /^[ \t]*$/) {
          print ""
          next
        }
        match($0, /^[ \t]*/)
        ind = RLENGTH
        if (ind <= run_ind) exit
        if (body_ind == "") body_ind = ind
        if (ind >= body_ind) print substr($0, body_ind + 1)
        else print substr($0, ind + 1)
        next
      }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (base_ind == "") base_ind = ind
      if (ind == base_ind && $0 ~ /^[ \t]*run:([ \t]|$)/) {
        run_ind = ind
        val = substr($0, ind + 5)
        sub(/^[ \t]+/, "", val)
        sub(/[ \t]+$/, "", val)
        # Strip inline comment on block indicator (e.g. `run: | # comment`)
        chk = val
        sub(/[ \t]+#.*$/, "", chk)
        if (chk ~ /^[>|]([+-]?[1-9]?|[1-9]?[+-]?)$/) {
          in_run = 1
          next
        }
        # Single-line run command (strip balanced YAML quotes if present)
        print clean(val)
        exit
      }
    }
  ' <<<"$block"
}

# split_job_steps <job_block> <out_dir>:
# Writes normalized step files <out_dir>/1, <out_dir>/2, ... and echoes count.
split_job_steps() {
  local job_block="$1" out_dir="$2"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  awk -v dir="$out_dir" '
    BEGIN { count = 0 }
    !in_steps {
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (job_key_ind == "") job_key_ind = ind
      if (ind == job_key_ind && $0 ~ /^[ \t]*steps:[ \t]*(#.*)?$/) {
        in_steps = 1
        steps_ind = ind
      }
      next
    }
    {
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) {
        if (count > 0) print $0 >> (dir "/" count)
        next
      }
      match($0, /^[ \t]*/)
      ind = RLENGTH
      is_dash = ($0 ~ /^[ \t]*-([ \t]|$)/)
      if (ind < steps_ind || (ind == steps_ind && !is_dash)) exit
      if (dash_ind == "") {
        if (!is_dash) exit
        dash_ind = ind
      }
      if (ind < dash_ind) exit
      if (ind == dash_ind && is_dash) {
        if (count > 0) close(dir "/" count)
        count++
        # Replace leading `-` with a space so the first key aligns with sibling keys.
        line = $0
        sub(/-/, " ", line)
        if (line !~ /^[ \t]*$/) print line > (dir "/" count)
        else printf "" > (dir "/" count)
        next
      }
      if (count > 0) print $0 >> (dir "/" count)
    }
    END { print count }
  ' <<<"$job_block"
}

# map_get <mapping_lines> <key>: prints value for key (last match if repeated).
map_get() {
  local mapping="$1" key="$2"
  awk -v k="$key" '
    index($0, k "=") == 1 { val = substr($0, length(k) + 2); found = 1 }
    END { if (found) print val }
  ' <<<"$mapping"
}

# strip_shell_comments <script>: removes comment lines and unquoted `# ...` tails.
strip_shell_comments() {
  awk '
    /^[ \t]*#/ { next }
    {
      in_sq = 0; in_dq = 0; esc = 0; out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (esc) { out = out c; esc = 0; continue }
        if (c == "\\" && !in_sq) { out = out c; esc = 1; continue }
        if (c == "\047" && !in_dq) { in_sq = !in_sq; out = out c; continue }
        if (c == "\"" && !in_sq) { in_dq = !in_dq; out = out c; continue }
        if (c == "#" && !in_sq && !in_dq && (i == 1 || substr($0, i - 1, 1) ~ /[ \t]/)) break
        out = out c
      }
      print out
    }
  ' <<<"$1"
}

# join_continuations <script>: collapses backslash-newline continuations.
join_continuations() {
  awk '
    /\\[ \t]*$/ {
      sub(/\\[ \t]*$/, " ")
      buf = buf $0
      next
    }
    {
      print buf $0
      buf = ""
    }
    END { if (buf != "") print buf }
  ' <<<"$1"
}

# split_shell_commands <script>: splits unquoted `;`, `&&`, `||` onto separate lines.
split_shell_commands() {
  awk '
    {
      in_sq = 0; in_dq = 0; esc = 0; out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (esc) { out = out c; esc = 0; continue }
        if (c == "\\" && !in_sq) { out = out c; esc = 1; continue }
        if (c == "\047" && !in_dq) { in_sq = !in_sq; out = out c; continue }
        if (c == "\"" && !in_sq) { in_dq = !in_dq; out = out c; continue }
        if (!in_sq && !in_dq) {
          if (c == ";") {
            print out; out = ""; continue
          }
          if ((c == "&" || c == "|") && i < n && substr($0, i + 1, 1) == c) {
            print out; out = ""; i++; continue
          }
        }
        out = out c
      }
      print out
    }
  ' <<<"$1"
}

# has_top_level_or <gha_expr>: returns 0 if `||` appears outside quotes/parens.
has_top_level_or() {
  awk '
    {
      s = $0
      sub(/^[ \t]*\$[{][{][ \t]*/, "", s)
      sub(/[ \t]*[}][}][ \t]*$/, "", s)
      in_sq = 0; in_dq = 0; depth = 0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\047" && !in_dq) { in_sq = !in_sq; continue }
        if (c == "\"" && !in_sq) { in_dq = !in_dq; continue }
        if (in_sq || in_dq) continue
        if (c == "(") depth++
        else if (c == ")" && depth > 0) depth--
        else if (depth == 0 && c == "|" && i < n && substr(s, i + 1, 1) == "|") {
          found = 1; exit
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' <<<"$1"
}

# expr_requires <gha_expr> <pattern>: true if expression matches <pattern>,
# is not weakened by a top-level `||`, and the match is not negated by `!`.
expr_requires() {
  local expr="$1" pat="$2"
  [[ -n "$expr" ]] || return 1
  if has_top_level_or "$expr"; then
    return 1
  fi
  grep -Eq "$pat" <<<"$expr" || return 1
  # Reject direct negation like `!(...)` or `! (...)` around the matched clause.
  if grep -Eq "![[:space:]]*\([[:space:]]*(${pat})" <<<"$expr"; then
    return 1
  fi
  return 0
}

# --- Requirement 1, 2, 3: Claude jobs ----------------------------------------

# check_claude_job <label> <file> <job_name> <expected_perms_sorted>
check_claude_job() {
  local label="$1" file="$2" job="$3" expected_perms="$4"
  local mint_case="$label: mints Claude App token with pinned action and CLAUDE_APP_*"
  local perm_case="$label: permission-* inputs match token table"
  local pass_case="$label: passes minted token to claude-code-action as github_token"

  if [[ ! -f "$file" ]]; then
    fail "$mint_case (missing file: $file)"
    fail "$perm_case (missing file: $file)"
    fail "$pass_case (missing file: $file)"
    return
  fi

  local job_block
  job_block="$(extract_job "$file" "$job")"
  if [[ -z "$job_block" ]]; then
    fail "$mint_case (missing job: $job)"
    fail "$perm_case (missing job: $job)"
    fail "$pass_case (missing job: $job)"
    return
  fi

  local steps_dir="$tmp/steps_${job}"
  local nsteps
  nsteps="$(split_job_steps "$job_block" "$steps_dir")"

  local mint_idx=0 mint_count=0 first_claude_idx=0 i step_text uses
  local claude_indices=""
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    uses="$(extract_scalar_or_block_field "$step_text" uses)"
    case "$uses" in
      actions/create-github-app-token | actions/create-github-app-token@*)
        mint_count=$((mint_count + 1))
        if [[ "$mint_idx" -eq 0 ]]; then mint_idx=$i; fi
        ;;
      anthropics/claude-code-action | anthropics/claude-code-action@*)
        if [[ "$first_claude_idx" -eq 0 ]]; then first_claude_idx=$i; fi
        claude_indices="${claude_indices} ${i}"
        ;;
    esac
  done

  if [[ "$mint_idx" -eq 0 ]]; then
    fail "$mint_case (no actions/create-github-app-token step)"
    fail "$perm_case (no actions/create-github-app-token step)"
    fail "$pass_case (no actions/create-github-app-token step)"
    return
  fi

  local mint_step mint_uses mint_id mint_with app_id priv_key
  mint_step="$(cat "$steps_dir/$mint_idx")"
  mint_uses="$(extract_scalar_or_block_field "$mint_step" uses)"
  mint_id="$(extract_scalar_or_block_field "$mint_step" id)"
  mint_with="$(extract_mapping_from_block "$mint_step" with)"
  app_id="$(map_get "$mint_with" app-id)"
  priv_key="$(map_get "$mint_with" private-key)"

  local mint_errs=""
  if [[ "$mint_count" -gt 1 ]]; then
    mint_errs="${mint_errs} expected 1 create-github-app-token step, found $mint_count;"
  fi
  if [[ "$mint_uses" != "$PINNED_APP_TOKEN_ACTION" ]]; then
    mint_errs="${mint_errs} uses=$mint_uses (want $PINNED_APP_TOKEN_ACTION);"
  fi
  if ! is_gha_expr "$app_id" "vars.CLAUDE_APP_ID"; then
    mint_errs="${mint_errs} app-id=$app_id (want \${{ vars.CLAUDE_APP_ID }});"
  fi
  if ! is_gha_expr "$priv_key" "secrets.CLAUDE_APP_PRIVATE_KEY"; then
    mint_errs="${mint_errs} private-key=$priv_key (want \${{ secrets.CLAUDE_APP_PRIVATE_KEY }});"
  fi
  if [[ -z "$mint_id" ]]; then
    mint_errs="${mint_errs} mint step has no id;"
  fi
  if [[ "$first_claude_idx" -eq 0 || "$mint_idx" -ge "$first_claude_idx" ]]; then
    mint_errs="${mint_errs} mint step must precede claude-code-action;"
  fi

  if [[ -z "$mint_errs" ]]; then
    pass "$mint_case"
  else
    fail "$mint_case ($mint_errs)"
  fi

  local actual_perms
  actual_perms="$(grep '^permission-' <<<"$mint_with" | LC_ALL=C sort || true)"
  if [[ "$actual_perms" == "$expected_perms" ]]; then
    pass "$perm_case"
  else
    fail "$perm_case (got [$(tr '\n' ' ' <<<"$actual_perms")], want [$(tr '\n' ' ' <<<"$expected_perms")])"
  fi

  if [[ -z "$claude_indices" ]]; then
    fail "$pass_case (no anthropics/claude-code-action step)"
    return
  fi

  local cidx claude_step claude_with gh_tok pass_errs=""
  for cidx in $claude_indices; do
    claude_step="$(cat "$steps_dir/$cidx")"
    claude_with="$(extract_mapping_from_block "$claude_step" with)"
    gh_tok="$(map_get "$claude_with" github_token)"
    if [[ -z "$mint_id" ]] || ! is_gha_expr "$gh_tok" "steps.${mint_id}.outputs.token"; then
      pass_errs="${pass_errs} step $cidx github_token=$gh_tok (want \${{ steps.${mint_id:-<id>}.outputs.token }});"
    fi
  done
  if [[ -z "$pass_errs" ]]; then
    pass "$pass_case"
  else
    fail "$pass_case ($pass_errs)"
  fi
}

check_claude_job \
  "claude.yml" \
  "$workflows/claude.yml" \
  "claude" \
  "$(printf '%s\n%s\n%s\n%s' \
    "permission-actions=read" \
    "permission-contents=write" \
    "permission-issues=write" \
    "permission-pull-requests=write")"

check_claude_job \
  "pr.yml claude-review" \
  "$workflows/pr.yml" \
  "claude-review" \
  "$(printf '%s\n%s\n%s' \
    "permission-contents=read" \
    "permission-issues=write" \
    "permission-pull-requests=write")"

check_claude_job \
  "deploy.yml report triage" \
  "$workflows/deploy.yml" \
  "report" \
  "$(printf '%s\n%s\n%s' \
    "permission-actions=read" \
    "permission-contents=read" \
    "permission-issues=write")"

# --- Requirement 2: claude-review has no permission-contents: write ----------

check_claude_review_no_contents_write() {
  local case_name="claude-review has no permission-contents: write"
  local file="$workflows/pr.yml"
  if [[ ! -f "$file" ]]; then
    fail "$case_name (missing file: $file)"
    return
  fi

  local job_block
  job_block="$(extract_job "$file" "claude-review")"
  if [[ -z "$job_block" ]]; then
    fail "$case_name (missing job: claude-review)"
    return
  fi

  local job_perms_scalar job_perms job_contents top_perms_scalar
  job_perms_scalar="$(extract_scalar_or_block_field "$job_block" permissions)"
  if [[ "$job_perms_scalar" == "write-all" ]]; then
    fail "$case_name (job permissions is write-all)"
    return
  fi
  job_perms="$(extract_mapping_from_block "$job_block" permissions)"
  job_contents="$(map_get "$job_perms" contents)"
  if [[ "$job_contents" == "write" ]]; then
    fail "$case_name (job permissions has contents: write)"
    return
  fi
  if [[ -z "$job_perms" && -z "$job_perms_scalar" ]]; then
    top_perms_scalar="$(extract_top_scalar "$file" permissions)"
    if [[ "$top_perms_scalar" == "write-all" ]]; then
      fail "$case_name (workflow permissions is write-all)"
      return
    fi
  fi

  local steps_dir="$tmp/steps_cr_ncw"
  local nsteps i step_text uses mint_found=0
  nsteps="$(split_job_steps "$job_block" "$steps_dir")"
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    uses="$(extract_scalar_or_block_field "$step_text" uses)"
    case "$uses" in
      actions/create-github-app-token | actions/create-github-app-token@*)
        mint_found=1
        local with_map perm_contents
        with_map="$(extract_mapping_from_block "$step_text" with)"
        if grep -Eq '^permission-contents=write$' <<<"$with_map"; then
          fail "$case_name (mint step sets permission-contents: write)"
          return
        fi
        perm_contents="$(map_get "$with_map" permission-contents)"
        if [[ "$perm_contents" != "read" ]]; then
          fail "$case_name (mint step must explicitly set permission-contents: read so App write permission is not inherited; got: ${perm_contents:-<unset>})"
          return
        fi
        ;;
    esac
  done

  if [[ "$mint_found" -eq 0 ]]; then
    fail "$case_name (no actions/create-github-app-token step in claude-review)"
    return
  fi

  pass "$case_name"
}

check_claude_review_no_contents_write

# --- Requirement 4: Review cap in claude-review (Proof criterion 3) ----------

# Fake gh for running the review-cap step without touching the network.
mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || { echo "fake gh: unsupported subcommand: ${1:-}" >&2; exit 2; }
shift
jq_expr=""
slurp=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq|-q) jq_expr="$2"; shift 2 ;;
    --jq=*) jq_expr="${1#--jq=}"; shift ;;
    -q=*) jq_expr="${1#-q=}"; shift ;;
    --slurp) slurp=1; shift ;;
    --paginate) shift ;;
    -H|--header|-X|--method|-f|--raw-field|-F|--field|--cache|--input|--hostname) shift 2 ;;
    -H=*|--header=*|-X=*|--method=*|--cache=*|--input=*|--hostname=*) shift ;;
    *) shift ;;
  esac
done
if [[ -n "$jq_expr" ]]; then
  if [[ "$slurp" -eq 1 ]]; then
    jq -s -r "$jq_expr" "$FIXTURE_COMMENTS_JSON"
  else
    jq -r "$jq_expr" "$FIXTURE_COMMENTS_JSON"
  fi
else
  if [[ "$slurp" -eq 1 ]]; then
    jq -s '.' "$FIXTURE_COMMENTS_JSON"
  else
    cat "$FIXTURE_COMMENTS_JSON"
  fi
fi
EOF
chmod +x "$tmp/fakebin/gh"

# substitute_gha_exprs <text> <slug>: replaces ${{ ... }} for running the cap step.
substitute_gha_exprs() {
  local text="$1" slug="$2"
  sed -E \
    -e "s/\\\$[{][{][[:space:]]*vars\\.CLAUDE_APP_SLUG[[:space:]]*[}][}]/$slug/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.repository[[:space:]]*[}][}]/acme\\/hello/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.event\\.pull_request\\.number[[:space:]]*[}][}]/42/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.token[[:space:]]*[}][}]/dummy-token/g" \
    <<<"$text"
}

# run_cap_step <job_env> <step_env> <run_body> <slug> <fixture_json_file>
# Sets CAP_RC and CAP_RUN_VAL (value of `run=` written to GITHUB_OUTPUT).
run_cap_step() {
  local job_env="$1" step_env="$2" run_body="$3" slug="$4" fixture="$5"
  local script_file="$tmp/cap_step.sh"
  local out_file="$tmp/cap_github_output"
  local sum_file="$tmp/cap_github_summary"
  : >"$out_file"
  : >"$sum_file"

  local env_file="$tmp/cap_env.sh"
  local env_kv_file="$tmp/cap_env.kv"
  : >"$env_file"
  : >"$env_kv_file"
  local line k v
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="$(substitute_gha_exprs "$v" "$slug")"
    v="$(sed -E 's/\$[{][{][^}]*[}][}]/dummy/g' <<<"$v")"
    printf 'export %s=%q\n' "$k" "$v" >>"$env_file"
    printf '%s=%s\n' "$k" "$v" >>"$env_kv_file"
  done < <(printf '%s\n%s\n' "$job_env" "$step_env")

  local rendered
  rendered="$(substitute_gha_exprs "$run_body" "$slug")"
  # Also resolve ${{ env.<KEY> }} expressions from the step's effective env.
  rendered="$(awk -v kv="$env_kv_file" '
    BEGIN {
      while ((getline line < kv) > 0) {
        p = index(line, "=")
        if (p > 0) vals[substr(line, 1, p - 1)] = substr(line, p + 1)
      }
      close(kv)
    }
    {
      s = $0
      for (k in vals) {
        re = "\\$[{][{][ \t]*env\\." k "[ \t]*[}][}]"
        repl = vals[k]
        gsub(/&/, "\\\\&", repl)
        gsub(re, repl, s)
      }
      print s
    }
  ' <<<"$rendered")"
  printf '%s\n' "$rendered" >"$script_file"

  CAP_RC=0
  (
    export PATH="$tmp/fakebin:$PATH"
    export GITHUB_REPOSITORY="acme/hello"
    export GITHUB_SERVER_URL="https://github.com"
    export GITHUB_RUN_ID="12345"
    export GITHUB_ACTOR="${slug}[bot]"
    export PR_NUMBER="42"
    export MAX_AUTO_REVIEWS="3"
    export GITHUB_OUTPUT="$out_file"
    export GITHUB_STEP_SUMMARY="$sum_file"
    export FIXTURE_COMMENTS_JSON="$fixture"
    # shellcheck disable=SC1090
    source "$env_file"
    # GitHub Actions Linux `run:` steps use `bash -eo pipefail` (not `-u`).
    bash -eo pipefail "$script_file" </dev/null >/dev/null 2>"$tmp/cap_err"
  ) || CAP_RC=$?
  CAP_RUN_VAL="$(awk -F= '$1 == "run" { val = $2 } END { print val }' "$out_file")"
}

check_review_cap() {
  local c_only="cap counts only CLAUDE_APP_SLUG"
  local c_others="marker from others ignored"
  local file="$workflows/pr.yml"

  if [[ ! -f "$file" ]]; then
    fail "$c_only (missing file: $file)"
    fail "$c_others (missing file: $file)"
    return
  fi

  local job_block
  job_block="$(extract_job "$file" "claude-review")"
  if [[ -z "$job_block" ]]; then
    fail "$c_only (missing job: claude-review)"
    fail "$c_others (missing job: claude-review)"
    return
  fi

  local steps_dir="$tmp/steps_cap"
  local nsteps i step_text step_id step_run cap_step="" cap_run=""
  nsteps="$(split_job_steps "$job_block" "$steps_dir")"
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    step_id="$(extract_scalar_or_block_field "$step_text" id)"
    step_run="$(extract_run_body "$step_text")"
    if [[ -n "$step_run" ]] && { grep -qF "<!-- claude-review -->" <<<"$step_text" || [[ "$step_id" == "quota" ]]; }; then
      cap_step="$step_text"
      cap_run="$step_run"
      break
    fi
  done

  if [[ -z "$cap_step" || -z "$cap_run" ]]; then
    fail "$c_only (no review-cap step found in claude-review)"
    fail "$c_others (no review-cap step found in claude-review)"
    return
  fi

  local wf_env job_env step_env run_clean
  wf_env="$(extract_top_mapping "$file" env)"
  job_env="$(extract_mapping_from_block "$job_block" env)"
  step_env="$(extract_mapping_from_block "$cap_step" env)"
  run_clean="$(strip_shell_comments "$cap_run")"

  # Combine workflow -> job -> step env (later overrides earlier).
  local combined_env
  combined_env="$(printf '%s\n%s\n' "$wf_env" "$job_env")"

  # Verify vars.CLAUDE_APP_SLUG is actually used (inline in run: or via an env var).
  local uses_slug=0
  if grep -Eq '\$[{][{][[:space:]]*vars\.CLAUDE_APP_SLUG[[:space:]]*[}][}]' <<<"$run_clean"; then
    uses_slug=1
  else
    local line k v
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      k="${line%%=*}"
      v="${line#*=}"
      if grep -Eq '\$[{][{][[:space:]]*vars\.CLAUDE_APP_SLUG[[:space:]]*[}][}]' <<<"$v"; then
        if grep -Eq "(\\\$[{]?${k}([^A-Za-z0-9_]|$)|env\.${k}([^A-Za-z0-9_]|$)|env\[['\"]${k}['\"]\])" <<<"$run_clean"; then
          uses_slug=1
          break
        fi
      fi
    done < <(printf '%s\n%s\n' "$combined_env" "$step_env")
  fi

  local test_slug="acme-claude"

  # Case A: "cap counts only CLAUDE_APP_SLUG"
  if [[ "$uses_slug" -ne 1 ]]; then
    fail "$c_only (cap step does not select vars.CLAUDE_APP_SLUG)"
  else
    # 1) 2 marked + 2 unmarked comments from acme-claude[bot], plus 3 marked comments
    #    from another slug (other-claude[bot]) -> still under cap (run=true).
    cat >"$tmp/fix_under.json" <<'EOF'
[
  {"id": 1, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReview 1"},
  {"id": 2, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReview 2"},
  {"id": 3, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review-skipped -->\nSkip notice"},
  {"id": 4, "user": {"login": "acme-claude[bot]"}, "body": "Plain reply without marker"},
  {"id": 5, "user": {"login": "other-claude[bot]"}, "body": "<!-- claude-review -->\nOther slug 1"},
  {"id": 6, "user": {"login": "other-claude[bot]"}, "body": "<!-- claude-review -->\nOther slug 2"},
  {"id": 7, "user": {"login": "other-claude[bot]"}, "body": "<!-- claude-review -->\nOther slug 3"}
]
EOF
    run_cap_step "$combined_env" "$step_env" "$cap_run" "$test_slug" "$tmp/fix_under.json"
    local under_rc="$CAP_RC" under_val="$CAP_RUN_VAL"

    # 2) Three marked comments from acme-claude[bot] -> cap reached (run=false).
    cat >"$tmp/fix_at_cap.json" <<'EOF'
[
  {"id": 1, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReview 1"},
  {"id": 2, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReview 2"},
  {"id": 3, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReview 3"}
]
EOF
    run_cap_step "$combined_env" "$step_env" "$cap_run" "$test_slug" "$tmp/fix_at_cap.json"
    local at_rc="$CAP_RC" at_val="$CAP_RUN_VAL"

    # 3) Same 3 acme-claude[bot] comments when CLAUDE_APP_SLUG is a different slug
    #    (beta-claude) -> must NOT count toward beta-claude's cap (run=true).
    run_cap_step "$combined_env" "$step_env" "$cap_run" "beta-claude" "$tmp/fix_at_cap.json"
    local diff_rc="$CAP_RC" diff_val="$CAP_RUN_VAL"

    if [[ "$under_rc" -eq 0 && "$under_val" == "true" && "$at_rc" -eq 0 && "$at_val" == "false" && "$diff_rc" -eq 0 && "$diff_val" == "true" ]]; then
      pass "$c_only"
    else
      fail "$c_only (under rc=$under_rc run=$under_val [want 0/true]; at-cap rc=$at_rc run=$at_val [want 0/false]; diff-slug rc=$diff_rc run=$diff_val [want 0/true]; err=$(cat "$tmp/cap_err" 2>/dev/null || true))"
    fi
  fi

  # Case B: "marker from others ignored"
  # 2 real comments from acme-claude[bot] + 7 marked comments from other logins
  # (including github-actions[bot], a human, another bot, and prefix/suffix spoofs).
  # Must still stay under cap (run=true) AND must select vars.CLAUDE_APP_SLUG.
  cat >"$tmp/fix_others.json" <<'EOF'
[
  {"id": 10, "user": {"login": "github-actions[bot]"}, "body": "<!-- claude-review -->\nOld bot"},
  {"id": 11, "user": {"login": "github-actions[bot]"}, "body": "<!-- claude-review -->\nOld bot 2"},
  {"id": 12, "user": {"login": "github-actions[bot]"}, "body": "<!-- claude-review -->\nOld bot 3"},
  {"id": 13, "user": {"login": "someone"}, "body": "<!-- claude-review -->\nHuman spoof"},
  {"id": 14, "user": {"login": "acme-agy[bot]"}, "body": "<!-- claude-review -->\nOther agent"},
  {"id": 15, "user": {"login": "evil-acme-claude[bot]"}, "body": "<!-- claude-review -->\nPrefix spoof"},
  {"id": 16, "user": {"login": "acme-claude"}, "body": "<!-- claude-review -->\nMissing bot suffix"},
  {"id": 17, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReal review 1"},
  {"id": 18, "user": {"login": "acme-claude[bot]"}, "body": "<!-- claude-review -->\nReal review 2"}
]
EOF
  run_cap_step "$combined_env" "$step_env" "$cap_run" "$test_slug" "$tmp/fix_others.json"
  if [[ "$uses_slug" -eq 1 && "$CAP_RC" -eq 0 && "$CAP_RUN_VAL" == "true" ]]; then
    pass "$c_others"
  else
    fail "$c_others (uses_slug=$uses_slug rc=$CAP_RC run=$CAP_RUN_VAL [want 1/0/true]; err=$(cat "$tmp/cap_err" 2>/dev/null || true))"
  fi
}

check_review_cap

# --- Requirement 5: dependabot-automerge.yml (FR-8, C2, amended C3) ----------

# on_has_event <file> <event_name>: true if `on:` triggers on <event_name>.
# Handles single scalar, flow list, flow mapping, block mapping, and block sequence forms.
on_has_event() {
  local file="$1" ev="$2"
  local inline
  inline="$(extract_top_scalar "$file" on)"
  if [[ -n "$inline" ]]; then
    if [[ "$inline" == "$ev" ]]; then
      return 0
    fi
    if [[ "$inline" == \[*\] ]]; then
      local inner="${inline#\[}"
      inner="${inner%\]}"
      awk -v target="$ev" '
        {
          n = split($0, parts, ",")
          for (i = 1; i <= n; i++) {
            s = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            gsub(/^["\047]|["\047]$/, "", s)
            if (s == target) { found = 1; exit }
          }
        }
        END { exit (found ? 0 : 1) }
      ' <<<"$inner"
      return $?
    fi
    if [[ "$inline" == \{*\} ]]; then
      local inner="${inline#\{}"
      inner="${inner%\}}"
      awk -v target="$ev" '
        {
          s = $0
          n = length(s)
          depth = 0; in_sq = 0; in_dq = 0; esc = 0; seg = ""
          for (i = 1; i <= n + 1; i++) {
            c = (i <= n ? substr(s, i, 1) : ",")
            if (esc) { seg = seg c; esc = 0; continue }
            if (c == "\\" && in_dq) { seg = seg c; esc = 1; continue }
            if (c == "\047" && !in_dq) { in_sq = !in_sq; seg = seg c; continue }
            if (c == "\"" && !in_sq) { in_dq = !in_dq; seg = seg c; continue }
            if (!in_sq && !in_dq) {
              if (c == "{" || c == "[") { depth++; seg = seg c; continue }
              if (c == "}" || c == "]") { if (depth > 0) depth--; seg = seg c; continue }
              if (c == "," && depth == 0) {
                col = index(seg, ":")
                if (col > 0) {
                  k = substr(seg, 1, col - 1)
                  gsub(/^[ \t]+|[ \t]+$/, "", k)
                  gsub(/^["\047]|["\047]$/, "", k)
                  if (k == target) { found = 1; exit }
                }
                seg = ""
                continue
              }
            }
            seg = seg c
          }
        }
        END { exit (found ? 0 : 1) }
      ' <<<"$inner"
      return $?
    fi
    return 1
  fi
  extract_top_section "$file" on | awk -v target="$ev" '
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (on_ind == "") on_ind = ind
      if (ind == on_ind) {
        if ($0 ~ ("^[ \t]*" target ":([ \t]|$)")) {
          found = 1
          exit
        }
        if ($0 ~ ("^[ \t]*-[ \t]+[\"\047]?" target "[\"\047]?([ \t]*(#.*)?$)")) {
          found = 1
          exit
        }
      }
    }
    END { exit (found ? 0 : 1) }
  '
}

# parse_flow_mapping <flow_str>: extracts top-level `key=value` pairs from `{ k: v, ... }`.
parse_flow_mapping() {
  local raw="$1"
  [[ "$raw" == \{*\} ]] || return 0
  local inner="${raw#\{}"
  inner="${inner%\}}"
  awk '
    {
      s = $0
      n = length(s)
      depth = 0; in_sq = 0; in_dq = 0; esc = 0; seg = ""
      for (i = 1; i <= n + 1; i++) {
        c = (i <= n ? substr(s, i, 1) : ",")
        if (esc) { seg = seg c; esc = 0; continue }
        if (c == "\\" && in_dq) { seg = seg c; esc = 1; continue }
        if (c == "\047" && !in_dq) { in_sq = !in_sq; seg = seg c; continue }
        if (c == "\"" && !in_sq) { in_dq = !in_dq; seg = seg c; continue }
        if (!in_sq && !in_dq) {
          if (c == "{" || c == "[") { depth++; seg = seg c; continue }
          if (c == "}" || c == "]") { if (depth > 0) depth--; seg = seg c; continue }
          if (c == "," && depth == 0) {
            col = index(seg, ":")
            if (col > 0) {
              k = substr(seg, 1, col - 1)
              v = substr(seg, col + 1)
              gsub(/^[ \t]+|[ \t]+$/, "", k)
              gsub(/^["\047]|["\047]$/, "", k)
              gsub(/^[ \t]+|[ \t]+$/, "", v)
              gsub(/^["\047]|["\047]$/, "", v)
              if (k != "") print k "=" v
            }
            seg = ""
            continue
          }
        }
        seg = seg c
      }
    }
  ' <<<"$inner"
}

# map_has_key <mapping_lines> <key>: true if key appears in mapping_lines.
map_has_key() {
  local mapping="$1" key="$2"
  awk -v k="$key" '
    index($0, k "=") == 1 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' <<<"$mapping"
}

# merge_step_uses_token <merge_env> <job_env> <merge_clean> <mint_id>:
# True iff GH_TOKEN / GITHUB_TOKEN in effect for the merge step is ${{ steps.<mint_id>.outputs.token }}.
merge_step_uses_token() {
  local merge_env="$1" job_env="$2" merge_clean="$3" mint_id="$4"
  local want="steps.${mint_id}.outputs.token"
  local step_gh step_gh2 job_gh job_gh2
  step_gh="$(map_get "$merge_env" GH_TOKEN)"
  step_gh2="$(map_get "$merge_env" GITHUB_TOKEN)"
  job_gh="$(map_get "$job_env" GH_TOKEN)"
  job_gh2="$(map_get "$job_env" GITHUB_TOKEN)"

  # Inline assignment in the shell script (e.g. `GH_TOKEN="${{ steps.ci.outputs.token }}" gh pr merge ...`)
  if grep -Eq "(^|[[:space:];&|(])(GH_TOKEN|GITHUB_TOKEN)=['\"]?\\\$[{][{][[:space:]]*steps\\.${mint_id}\\.outputs\\.token[[:space:]]*[}][}]['\"]?" <<<"$merge_clean"; then
    return 0
  fi

  # Step-level env takes precedence; gh prefers GH_TOKEN over GITHUB_TOKEN.
  if [[ -n "$step_gh" ]]; then
    is_gha_expr "$step_gh" "$want"
    return $?
  fi
  if [[ -n "$step_gh2" ]]; then
    if [[ -n "$job_gh" ]]; then
      is_gha_expr "$job_gh" "$want"
      return $?
    fi
    is_gha_expr "$step_gh2" "$want"
    return $?
  fi
  if [[ -n "$job_gh" ]]; then
    is_gha_expr "$job_gh" "$want"
    return $?
  fi
  if [[ -n "$job_gh2" ]]; then
    is_gha_expr "$job_gh2" "$want"
    return $?
  fi
  return 1
}

# extract_match_head_commit_args <cmd_line>:
# Prints every raw argument passed to --match-head-commit (space or `=` form),
# one per line, preserving outer quotes and keeping `${{ ... }}` intact.
# Prints `__MISSING__` if a trailing --match-head-commit has no value.
extract_match_head_commit_args() {
  awk '
    {
      s = $0
      n = length(s)
      i = 1
      ntok = 0
      while (i <= n) {
        while (i <= n && substr(s, i, 1) ~ /[ \t|&;()<>]/) i++
        if (i > n) break
        tok = ""
        in_sq = 0
        in_dq = 0
        while (i <= n) {
          c = substr(s, i, 1)
          if (!in_sq && !in_dq && c ~ /[ \t|&;()<>]/) break
          if (!in_sq && substr(s, i, 3) == "${{") {
            rest = substr(s, i + 3)
            endp = index(rest, "}}")
            if (endp > 0) {
              tok = tok substr(s, i, 3 + endp + 1)
              i += 3 + endp + 1
              continue
            }
          }
          if (c == "\\" && !in_sq && i < n) {
            tok = tok substr(s, i, 2)
            i += 2
            continue
          }
          if (c == "\047" && !in_dq) {
            in_sq = !in_sq
            tok = tok c
            i++
            continue
          }
          if (c == "\"" && !in_sq) {
            in_dq = !in_dq
            tok = tok c
            i++
            continue
          }
          tok = tok c
          i++
        }
        ntok++
        toks[ntok] = tok
      }
      for (j = 1; j <= ntok; j++) {
        if (toks[j] == "--match-head-commit") {
          if (j < ntok) {
            print toks[j + 1]
            j++
          } else {
            print "__MISSING__"
          }
        } else if (index(toks[j], "--match-head-commit=") == 1) {
          print substr(toks[j], 21)
        }
      }
    }
  ' <<<"$1"
}

# match_head_commit_arg_is_pr_sha <raw_arg> <merge_env> <job_env> <wf_env>:
# True iff raw_arg is `${{ github.event.pull_request.head.sha }}` inline or
# a $VAR / ${VAR} whose effective env resolves to that expression.
match_head_commit_arg_is_pr_sha() {
  local raw="$1" merge_env="$2" job_env="$3" wf_env="$4"
  local unq was_sq=0
  [[ -n "$raw" && "$raw" != "__MISSING__" ]] || return 1

  if [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
    unq="${raw#\"}"
    unq="${unq%\"}"
  elif [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
    unq="${raw#\'}"
    unq="${unq%\'}"
    was_sq=1
  else
    unq="$raw"
  fi

  if is_gha_expr "$unq" "github.event.pull_request.head.sha"; then
    return 0
  fi

  [[ "$was_sq" -eq 0 ]] || return 1

  local var_name=""
  local var_re1='^[$]([A-Za-z_][A-Za-z0-9_]*)$'
  local var_re2='^[$][{]([A-Za-z_][A-Za-z0-9_]*)[}]$'
  if [[ "$unq" =~ $var_re1 ]]; then
    var_name="${BASH_REMATCH[1]}"
  elif [[ "$unq" =~ $var_re2 ]]; then
    var_name="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  local env_val=""
  if map_has_key "$merge_env" "$var_name"; then
    env_val="$(map_get "$merge_env" "$var_name")"
  elif map_has_key "$job_env" "$var_name"; then
    env_val="$(map_get "$job_env" "$var_name")"
  elif map_has_key "$wf_env" "$var_name"; then
    env_val="$(map_get "$wf_env" "$var_name")"
  else
    return 1
  fi

  is_gha_expr "$env_val" "github.event.pull_request.head.sha"
}

# merge_cmd_has_match_head_commit <cmd_line> <merge_env> <job_env> <wf_env>:
# True iff cmd_line passes --match-head-commit at least once and every occurrence
# resolves to `${{ github.event.pull_request.head.sha }}`.
merge_cmd_has_match_head_commit() {
  local cmd_line="$1" merge_env="$2" job_env="$3" wf_env="$4"
  local args raw count=0
  args="$(extract_match_head_commit_args "$cmd_line")"
  [[ -n "$args" ]] || return 1
  while IFS= read -r raw; do
    count=$((count + 1))
    match_head_commit_arg_is_pr_sha "$raw" "$merge_env" "$job_env" "$wf_env" || return 1
  done <<<"$args"
  [[ "$count" -ge 1 ]]
}

# Fake gh and fake sleep for running the wait step without touching the network.
mkdir -p "$tmp/wait_fakebin"
cat >"$tmp/wait_fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${GH_TOKEN:-}" >>"$WAIT_GH_TOKENS_LOG"

count=0
if [[ -f "$WAIT_GH_COUNT_FILE" ]]; then
  count="$(cat "$WAIT_GH_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$WAIT_GH_COUNT_FILE"

if [[ "${1:-}" != "api" ]]; then
  raw_args="$*"
  printf '%s\n' "${raw_args//$'\n'/ }" >>"$WAIT_GH_ARGS_LOG"
  echo "fake gh: unsupported subcommand: ${1:-}" >&2
  exit 2
fi
shift

endpoint=""
fields=""
jq_expr=""
slurp=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq|-q) jq_expr="$2"; shift 2 ;;
    --jq=*) jq_expr="${1#--jq=}"; shift ;;
    -q=*) jq_expr="${1#-q=}"; shift ;;
    -q*) jq_expr="${1#-q}"; shift ;;
    --slurp) slurp=1; shift ;;
    --paginate|-i|--include|--silent|--verbose) shift ;;
    -f|--raw-field|-F|--field)
      fields="${fields} $2"
      shift 2
      ;;
    -f=*|--raw-field=*|-F=*|--field=*)
      fields="${fields} ${1#*=}"
      shift
      ;;
    -f*) fields="${fields} ${1#-f}"; shift ;;
    -F*) fields="${fields} ${1#-F}"; shift ;;
    -H|--header|-X|--method|--cache|--input|--hostname|-t|--template|-p|--preview) shift 2 ;;
    -H=*|--header=*|-X=*|--method=*|--cache=*|--input=*|--hostname=*|-t=*|--template=*|-p=*|--preview=*) shift ;;
    -*) shift ;;
    *)
      if [[ -z "$endpoint" ]]; then
        endpoint="$1"
      fi
      shift
      ;;
  esac
done

logged="${endpoint}${fields}"
printf '%s\n' "${logged//$'\n'/ }" >>"$WAIT_GH_ARGS_LOG"

fixture="$WAIT_FIXTURES_DIR/${count}.json"
if [[ ! -f "$fixture" ]]; then
  # Reuse the last numbered fixture if called more times than fixtures exist.
  last=""
  i=1
  while [[ -f "$WAIT_FIXTURES_DIR/${i}.json" ]]; do
    last="$WAIT_FIXTURES_DIR/${i}.json"
    i=$((i + 1))
  done
  fixture="$last"
fi
[[ -n "$fixture" && -f "$fixture" ]] || { echo "fake gh: no fixture for call $count" >&2; exit 2; }

if [[ -n "$jq_expr" ]]; then
  if [[ "$slurp" -eq 1 ]]; then
    jq -s -r "$jq_expr" "$fixture"
  else
    jq -r "$jq_expr" "$fixture"
  fi
else
  if [[ "$slurp" -eq 1 ]]; then
    jq -s '.' "$fixture"
  else
    cat "$fixture"
  fi
fi
EOF
chmod +x "$tmp/wait_fakebin/gh"

cat >"$tmp/wait_fakebin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$WAIT_SLEEP_LOG"
EOF
chmod +x "$tmp/wait_fakebin/sleep"

cat >"$tmp/wait_runner.sh" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
export PATH="$1:$PATH"
export GITHUB_REPOSITORY="$2"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_RUN_ID="12345"
export GITHUB_OUTPUT="$3"
export GITHUB_STEP_SUMMARY="$4"
# shellcheck disable=SC1090
source "$5"
exec bash -eo pipefail "$6"
EOF
chmod +x "$tmp/wait_runner.sh"

STUB_WAIT_REPO="acme/hello"
STUB_WAIT_HEAD_SHA="deadbeef0123456789abcdef0123456789abcdef"
STUB_WAIT_GH_TOKEN="stub-github-token-ci-ok"

# substitute_wait_gha_exprs <text>: replaces ${{ ... }} for running the wait step.
substitute_wait_gha_exprs() {
  local text="$1"
  local repo_esc="${STUB_WAIT_REPO//\//\\/}"
  sed -E \
    -e "s/\\\$[{][{][[:space:]]*github\\.token[[:space:]]*[}][}]/$STUB_WAIT_GH_TOKEN/g" \
    -e "s/\\\$[{][{][[:space:]]*secrets\\.GITHUB_TOKEN[[:space:]]*[}][}]/$STUB_WAIT_GH_TOKEN/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.event\\.pull_request\\.head\\.sha[[:space:]]*[}][}]/$STUB_WAIT_HEAD_SHA/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.event\\.pull_request\\.number[[:space:]]*[}][}]/42/g" \
    -e "s/\\\$[{][{][[:space:]]*github\\.repository[[:space:]]*[}][}]/$repo_esc/g" \
    <<<"$text"
}

# run_wait_step <wf_env> <job_env> <step_env> <run_body> <fixtures_dir>
# Sets WAIT_RC, WAIT_CONCLUSION, WAIT_GH_CALLS, WAIT_SLEEP_CALLS,
# WAIT_GH_ARGS_FILE, WAIT_GH_TOKENS_FILE, WAIT_ERR_FILE.
run_wait_step() {
  local wf_env="$1" job_env="$2" step_env="$3" run_body="$4" fixtures_dir="$5"
  local script_file="$tmp/wait_step.sh"
  local out_file="$tmp/wait_github_output"
  local sum_file="$tmp/wait_github_summary"
  local env_file="$tmp/wait_env.sh"
  local env_kv_file="$tmp/wait_env.kv"
  local count_file="$tmp/wait_gh_count"
  WAIT_GH_ARGS_FILE="$tmp/wait_gh_args.log"
  WAIT_GH_TOKENS_FILE="$tmp/wait_gh_tokens.log"
  WAIT_ERR_FILE="$tmp/wait_err"
  local sleep_log="$tmp/wait_sleep.log"

  : >"$out_file"
  : >"$sum_file"
  : >"$env_file"
  : >"$env_kv_file"
  printf '0\n' >"$count_file"
  : >"$WAIT_GH_ARGS_FILE"
  : >"$WAIT_GH_TOKENS_FILE"
  : >"$sleep_log"
  : >"$WAIT_ERR_FILE"

  local line k v
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="$(substitute_wait_gha_exprs "$v")"
    v="$(sed -E 's/\$[{][{][^}]*[}][}]/dummy/g' <<<"$v")"
    printf 'export %s=%q\n' "$k" "$v" >>"$env_file"
    printf '%s=%s\n' "$k" "$v" >>"$env_kv_file"
  done < <(printf '%s\n%s\n%s\n' "$wf_env" "$job_env" "$step_env")

  # Override TRIES=3 and INTERVAL=0 for deterministic fast behaviour tests.
  printf 'export TRIES=3\nexport INTERVAL=0\n' >>"$env_file"
  printf 'TRIES=3\nINTERVAL=0\n' >>"$env_kv_file"

  local rendered
  rendered="$(substitute_wait_gha_exprs "$run_body")"
  rendered="$(awk -v kv="$env_kv_file" '
    BEGIN {
      while ((getline line < kv) > 0) {
        p = index(line, "=")
        if (p > 0) vals[substr(line, 1, p - 1)] = substr(line, p + 1)
      }
      close(kv)
    }
    {
      s = $0
      for (k in vals) {
        re = "\\$[{][{][ \t]*env\\." k "[ \t]*[}][}]"
        repl = vals[k]
        gsub(/&/, "\\\\&", repl)
        gsub(re, repl, s)
      }
      print s
    }
  ' <<<"$rendered")"
  rendered="$(sed -E 's/\$[{][{][^}]*[}][}]/dummy/g' <<<"$rendered")"
  printf '%s\n' "$rendered" >"$script_file"

  WAIT_RC=0
  env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u HEAD_SHA \
    -u TRIES \
    -u INTERVAL \
    "WAIT_FIXTURES_DIR=$fixtures_dir" \
    "WAIT_GH_COUNT_FILE=$count_file" \
    "WAIT_GH_ARGS_LOG=$WAIT_GH_ARGS_FILE" \
    "WAIT_GH_TOKENS_LOG=$WAIT_GH_TOKENS_FILE" \
    "WAIT_SLEEP_LOG=$sleep_log" \
    "$tmp/wait_runner.sh" \
    "$tmp/wait_fakebin" \
    "$STUB_WAIT_REPO" \
    "$out_file" \
    "$sum_file" \
    "$env_file" \
    "$script_file" \
    </dev/null >/dev/null 2>"$WAIT_ERR_FILE" || WAIT_RC=$?

  WAIT_CONCLUSION="$(awk 'index($0, "conclusion=") == 1 { val = substr($0, 12) } END { print val }' "$out_file")"
  WAIT_GH_CALLS="$(tr -d '[:space:]' <"$count_file")"
  WAIT_SLEEP_CALLS="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
}

check_dependabot_automerge() {
  local c_trig="dependabot-automerge: triggers on pull_request and not workflow_run or pull_request_target"
  local c_actor="dependabot-automerge: requires actor to be dependabot[bot]"
  local c_author="dependabot-automerge: requires PR author to be dependabot[bot]"
  local c_perms="dependabot-automerge: job permissions include checks: read and grant no write"
  local c_wait="dependabot-automerge: wait step (id: ci_ok) order, env and timeout-minutes"
  local c_wait_a="dependabot-automerge wait step: completed/success on first poll writes conclusion=success, calls gh once, no sleep"
  local c_wait_b="dependabot-automerge wait step: completed/failure writes conclusion=failure"
  local c_wait_c="dependabot-automerge wait step: in_progress then completed/success sleeps once and writes conclusion=success"
  local c_wait_d="dependabot-automerge wait step: empty check_runs on every poll writes conclusion=timeout after 3 polls and exits 0"
  local c_wait_e="dependabot-automerge wait step: highest check-run id wins (id 1 success, id 2 failure -> conclusion=failure)"
  local c_wait_f="dependabot-automerge wait step: gh call names stub head SHA and check_name=ci-ok with github.token"
  local c_mint="dependabot-automerge: mints CI App token with pinned action, CI_APP_*, permissions and ci_ok gate"
  local c_merge="dependabot-automerge: merges after ci_ok with --squash, --match-head-commit, CI token and never --auto"

  local file="$workflows/dependabot-automerge.yml"
  if [[ ! -f "$file" ]]; then
    fail "$c_trig (missing file: $file)"
    fail "$c_actor (missing file: $file)"
    fail "$c_author (missing file: $file)"
    fail "$c_perms (missing file: $file)"
    fail "$c_wait (missing file: $file)"
    fail "$c_wait_a (missing file: $file)"
    fail "$c_wait_b (missing file: $file)"
    fail "$c_wait_c (missing file: $file)"
    fail "$c_wait_d (missing file: $file)"
    fail "$c_wait_e (missing file: $file)"
    fail "$c_wait_f (missing file: $file)"
    fail "$c_mint (missing file: $file)"
    fail "$c_merge (missing file: $file)"
    return
  fi

  # Find the merge job (contains create-github-app-token or gh pr merge, else first job).
  local job_name="" candidate_job="" job_block=""
  while IFS= read -r candidate_job; do
    [[ -n "$candidate_job" ]] || continue
    local blk
    blk="$(extract_job "$file" "$candidate_job")"
    if grep -Eq '(actions/create-github-app-token|gh pr merge)' <<<"$blk"; then
      job_name="$candidate_job"
      job_block="$blk"
      break
    fi
    if [[ -z "$job_name" ]]; then
      job_name="$candidate_job"
      job_block="$blk"
    fi
  done < <(list_jobs "$file")

  if [[ -z "$job_block" ]]; then
    fail "$c_trig (no job found in $file)"
    fail "$c_actor (no job found in $file)"
    fail "$c_author (no job found in $file)"
    fail "$c_perms (no job found in $file)"
    fail "$c_wait (no job found in $file)"
    fail "$c_wait_a (no job found in $file)"
    fail "$c_wait_b (no job found in $file)"
    fail "$c_wait_c (no job found in $file)"
    fail "$c_wait_d (no job found in $file)"
    fail "$c_wait_e (no job found in $file)"
    fail "$c_wait_f (no job found in $file)"
    fail "$c_mint (no job found in $file)"
    fail "$c_merge (no job found in $file)"
    return
  fi

  local steps_dir="$tmp/steps_dep"
  local nsteps i step_text uses step_id run_body run_clean
  nsteps="$(split_job_steps "$job_block" "$steps_dir")"

  local merge_cmd_re='(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|)]|$)'
  local fetch_meta_idx=0 wait_idx=0 wait_count=0 mint_idx=0 mint_count=0 merge_idx=0 merge_indices=""
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    uses="$(extract_scalar_or_block_field "$step_text" uses)"
    step_id="$(extract_scalar_or_block_field "$step_text" id)"
    case "$uses" in
      dependabot/fetch-metadata | dependabot/fetch-metadata@*)
        if [[ "$fetch_meta_idx" -eq 0 ]]; then fetch_meta_idx=$i; fi
        ;;
      actions/create-github-app-token | actions/create-github-app-token@*)
        mint_count=$((mint_count + 1))
        if [[ "$mint_idx" -eq 0 ]]; then mint_idx=$i; fi
        ;;
    esac
    if [[ "$step_id" == "ci_ok" ]]; then
      wait_count=$((wait_count + 1))
      if [[ "$wait_idx" -eq 0 ]]; then wait_idx=$i; fi
    fi
    run_body="$(extract_run_body "$step_text")"
    run_clean="$(join_continuations "$(strip_shell_comments "$run_body")")"
    if grep -Eq "$merge_cmd_re" <<<"$run_clean"; then
      if [[ "$merge_idx" -eq 0 ]]; then merge_idx=$i; fi
      merge_indices="${merge_indices} ${i}"
    fi
  done

  local wf_env job_env job_if mint_if="" merge_if=""
  wf_env="$(extract_top_mapping "$file" env)"
  job_env="$(extract_mapping_from_block "$job_block" env)"
  job_if="$(extract_scalar_or_block_field "$job_block" if)"
  if [[ "$mint_idx" -gt 0 ]]; then
    mint_if="$(extract_scalar_or_block_field "$(cat "$steps_dir/$mint_idx")" if)"
  fi
  if [[ "$merge_idx" -gt 0 ]]; then
    merge_if="$(extract_scalar_or_block_field "$(cat "$steps_dir/$merge_idx")" if)"
  fi

  local ci_ok_re="steps\.ci_ok\.outputs\.conclusion[[:space:]]*==[[:space:]]*['\"]success['\"]|['\"]success['\"][[:space:]]*==[[:space:]]*steps\.ci_ok\.outputs\.conclusion"

  # 5a. Trigger: pull_request only (never workflow_run or pull_request_target)
  local trig_errs=""
  if ! on_has_event "$file" pull_request; then
    trig_errs="${trig_errs} on: does not trigger on pull_request;"
  fi
  if on_has_event "$file" workflow_run; then
    trig_errs="${trig_errs} on: must not trigger on workflow_run;"
  fi
  if on_has_event "$file" pull_request_target; then
    trig_errs="${trig_errs} on: must not trigger on pull_request_target;"
  fi
  if [[ -z "$trig_errs" ]]; then
    pass "$c_trig"
  else
    fail "$c_trig ($trig_errs)"
  fi

  # 5b. Actor must be dependabot[bot] (C2)
  local actor_re="github\.actor[[:space:]]*==[[:space:]]*['\"]dependabot\[bot\]['\"]|['\"]dependabot\[bot\]['\"][[:space:]]*==[[:space:]]*github\.actor"
  local has_actor=0
  if expr_requires "$job_if" "$actor_re"; then
    has_actor=1
  elif [[ "$mint_idx" -gt 0 && "$merge_idx" -gt 0 ]] \
    && expr_requires "$mint_if" "$actor_re" \
    && expr_requires "$merge_if" "$actor_re"; then
    has_actor=1
  fi
  if [[ "$has_actor" -eq 1 ]]; then
    pass "$c_actor"
  else
    fail "$c_actor (missing github.actor == 'dependabot[bot]' gate in job/step if)"
  fi

  # 5c. PR author must be dependabot[bot] (C2)
  local pr_if_re="github\.event\.pull_request\.user\.login[[:space:]]*==[[:space:]]*['\"]dependabot\[bot\]['\"]|['\"]dependabot\[bot\]['\"][[:space:]]*==[[:space:]]*github\.event\.pull_request\.user\.login"
  local has_author=0
  if expr_requires "$job_if" "$pr_if_re"; then
    has_author=1
  elif [[ "$mint_idx" -gt 0 && "$merge_idx" -gt 0 ]] \
    && expr_requires "$mint_if" "$pr_if_re" \
    && expr_requires "$merge_if" "$pr_if_re"; then
    has_author=1
  fi
  if [[ "$has_author" -eq 1 ]]; then
    pass "$c_author"
  else
    fail "$c_author (missing github.event.pull_request.user.login == 'dependabot[bot]' gate in job/step if)"
  fi

  # 5d. Job GITHUB_TOKEN permissions include checks: read and grant no write
  local perms_errs="" job_perms_scalar job_perms checks_perm write_perms
  job_perms_scalar="$(extract_scalar_or_block_field "$job_block" permissions)"
  job_perms="$(extract_mapping_from_block "$job_block" permissions)"
  if [[ -z "$job_perms" && "$job_perms_scalar" == \{*\} ]]; then
    job_perms="$(parse_flow_mapping "$job_perms_scalar")"
  fi
  if [[ "$job_perms_scalar" == "write-all" ]]; then
    perms_errs="${perms_errs} job permissions is write-all;"
  fi
  if [[ -z "$job_perms" ]]; then
    perms_errs="${perms_errs} missing job-level permissions mapping with checks: read;"
  else
    checks_perm="$(map_get "$job_perms" checks)"
    if [[ "$checks_perm" != "read" ]]; then
      perms_errs="${perms_errs} job permissions checks=${checks_perm:-<unset>} (want read);"
    fi
    write_perms="$(grep -Ev '=(read|none)$' <<<"$job_perms" || true)"
    if [[ -n "$write_perms" ]]; then
      perms_errs="${perms_errs} job permissions must not grant write: $(tr '\n' ' ' <<<"$write_perms");"
    fi
  fi
  if [[ -z "$perms_errs" ]]; then
    pass "$c_perms"
  else
    fail "$c_perms ($perms_errs)"
  fi

  # 5e. Wait step (id: ci_ok) structural contract + behaviour cases (a-f)
  local wait_step="" wait_env="" wait_run="" wait_errs=""
  if [[ "$fetch_meta_idx" -eq 0 ]]; then
    wait_errs="${wait_errs} missing dependabot/fetch-metadata step;"
  fi
  if [[ "$wait_idx" -eq 0 ]]; then
    wait_errs="${wait_errs} missing wait step with id: ci_ok;"
  else
    wait_step="$(cat "$steps_dir/$wait_idx")"
    wait_env="$(extract_mapping_from_block "$wait_step" env)"
    wait_run="$(extract_run_body "$wait_step")"

    if [[ "$wait_count" -gt 1 ]]; then
      wait_errs="${wait_errs} expected 1 step with id: ci_ok, found $wait_count;"
    fi
    if [[ "$fetch_meta_idx" -gt 0 && "$wait_idx" -le "$fetch_meta_idx" ]]; then
      wait_errs="${wait_errs} ci_ok wait step ($wait_idx) must come after dependabot/fetch-metadata ($fetch_meta_idx);"
    fi
    if [[ "$mint_idx" -gt 0 && "$wait_idx" -ge "$mint_idx" ]]; then
      wait_errs="${wait_errs} ci_ok wait step ($wait_idx) must precede mint step ($mint_idx);"
    fi
    if [[ -z "$wait_run" ]]; then
      wait_errs="${wait_errs} ci_ok wait step has no run: body;"
    fi

    local w_gh_token w_head_sha w_tries w_interval
    w_gh_token="$(map_get "$wait_env" GH_TOKEN)"
    w_head_sha="$(map_get "$wait_env" HEAD_SHA)"
    w_tries="$(map_get "$wait_env" TRIES)"
    w_interval="$(map_get "$wait_env" INTERVAL)"

    if ! is_gha_expr "$w_gh_token" "github.token" && ! is_gha_expr "$w_gh_token" "secrets.GITHUB_TOKEN"; then
      wait_errs="${wait_errs} wait step env GH_TOKEN=${w_gh_token:-<unset>} (want \${{ github.token }});"
    fi
    if ! is_gha_expr "$w_head_sha" "github.event.pull_request.head.sha"; then
      wait_errs="${wait_errs} wait step env HEAD_SHA=${w_head_sha:-<unset>} (want \${{ github.event.pull_request.head.sha }});"
    fi
    if [[ ! "$w_tries" =~ ^[1-9][0-9]*$ ]]; then
      wait_errs="${wait_errs} wait step env TRIES=${w_tries:-<unset>} (want positive integer);"
    fi
    if [[ ! "$w_interval" =~ ^[0-9]+$ ]]; then
      wait_errs="${wait_errs} wait step env INTERVAL=${w_interval:-<unset>} (want integer seconds);"
    fi

    local job_timeout wait_timeout
    job_timeout="$(extract_scalar_or_block_field "$job_block" timeout-minutes)"
    wait_timeout="$(extract_scalar_or_block_field "$wait_step" timeout-minutes)"
    if [[ ! "$job_timeout" =~ ^[1-9][0-9]*$ && ! "$wait_timeout" =~ ^[1-9][0-9]*$ ]]; then
      wait_errs="${wait_errs} neither job nor ci_ok wait step sets timeout-minutes;"
    fi
  fi

  if [[ -z "$wait_errs" ]]; then
    pass "$c_wait"
  else
    fail "$c_wait ($wait_errs)"
  fi

  if [[ "$wait_idx" -eq 0 || -z "$wait_run" ]]; then
    fail "$c_wait_a (no ci_ok wait step)"
    fail "$c_wait_b (no ci_ok wait step)"
    fail "$c_wait_c (no ci_ok wait step)"
    fail "$c_wait_d (no ci_ok wait step)"
    fail "$c_wait_e (no ci_ok wait step)"
    fail "$c_wait_f (no ci_ok wait step)"
  else
    # Case a: first poll: one ci-ok run, completed/success -> conclusion=success, gh called once, no sleep.
    local dir_a="$tmp/wait_fix_a"
    mkdir -p "$dir_a"
    cat >"$dir_a/1.json" <<'EOF'
{"total_count":1,"check_runs":[{"id":101,"name":"ci-ok","status":"completed","conclusion":"success"}]}
EOF
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_a"
    if [[ "$WAIT_RC" -eq 0 && "$WAIT_CONCLUSION" == "success" && "$WAIT_GH_CALLS" -eq 1 && "$WAIT_SLEEP_CALLS" -eq 0 ]]; then
      pass "$c_wait_a"
    else
      fail "$c_wait_a (rc=$WAIT_RC conclusion=$WAIT_CONCLUSION gh_calls=$WAIT_GH_CALLS sleep_calls=$WAIT_SLEEP_CALLS [want 0/success/1/0]; err=$(cat "$WAIT_ERR_FILE" 2>/dev/null || true))"
    fi

    # Case b: completed/failure -> conclusion=failure.
    local dir_b="$tmp/wait_fix_b"
    mkdir -p "$dir_b"
    cat >"$dir_b/1.json" <<'EOF'
{"total_count":1,"check_runs":[{"id":102,"name":"ci-ok","status":"completed","conclusion":"failure"}]}
EOF
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_b"
    if [[ "$WAIT_RC" -eq 0 && "$WAIT_CONCLUSION" == "failure" && "$WAIT_GH_CALLS" -eq 1 && "$WAIT_SLEEP_CALLS" -eq 0 ]]; then
      pass "$c_wait_b"
    else
      fail "$c_wait_b (rc=$WAIT_RC conclusion=$WAIT_CONCLUSION gh_calls=$WAIT_GH_CALLS sleep_calls=$WAIT_SLEEP_CALLS [want 0/failure/1/0]; err=$(cat "$WAIT_ERR_FILE" 2>/dev/null || true))"
    fi

    # Case c: first poll in_progress, second completed/success -> conclusion=success, exactly one sleep.
    local dir_c="$tmp/wait_fix_c"
    mkdir -p "$dir_c"
    cat >"$dir_c/1.json" <<'EOF'
{"total_count":1,"check_runs":[{"id":103,"name":"ci-ok","status":"in_progress","conclusion":null}]}
EOF
    cat >"$dir_c/2.json" <<'EOF'
{"total_count":1,"check_runs":[{"id":103,"name":"ci-ok","status":"completed","conclusion":"success"}]}
EOF
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_c"
    if [[ "$WAIT_RC" -eq 0 && "$WAIT_CONCLUSION" == "success" && "$WAIT_GH_CALLS" -eq 2 && "$WAIT_SLEEP_CALLS" -eq 1 ]]; then
      pass "$c_wait_c"
    else
      fail "$c_wait_c (rc=$WAIT_RC conclusion=$WAIT_CONCLUSION gh_calls=$WAIT_GH_CALLS sleep_calls=$WAIT_SLEEP_CALLS [want 0/success/2/1]; err=$(cat "$WAIT_ERR_FILE" 2>/dev/null || true))"
    fi

    # Case d: {"total_count":0,"check_runs":[]} on every poll -> conclusion=timeout, gh called 3 times, exit 0.
    local dir_d="$tmp/wait_fix_d"
    mkdir -p "$dir_d"
    printf '{"total_count":0,"check_runs":[]}\n' >"$dir_d/1.json"
    printf '{"total_count":0,"check_runs":[]}\n' >"$dir_d/2.json"
    printf '{"total_count":0,"check_runs":[]}\n' >"$dir_d/3.json"
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_d"
    if [[ "$WAIT_RC" -eq 0 && "$WAIT_CONCLUSION" == "timeout" && "$WAIT_GH_CALLS" -eq 3 && "$WAIT_SLEEP_CALLS" -eq 2 ]]; then
      pass "$c_wait_d"
    else
      fail "$c_wait_d (rc=$WAIT_RC conclusion=$WAIT_CONCLUSION gh_calls=$WAIT_GH_CALLS sleep_calls=$WAIT_SLEEP_CALLS [want 0/timeout/3/2]; err=$(cat "$WAIT_ERR_FILE" 2>/dev/null || true))"
    fi

    # Case e: two runs, id 1 completed/success and id 2 completed/failure -> conclusion=failure
    # (tested in both array orders so neither [0] nor [-1] shortcuts pass).
    local dir_e1="$tmp/wait_fix_e1" dir_e2="$tmp/wait_fix_e2"
    mkdir -p "$dir_e1" "$dir_e2"
    cat >"$dir_e1/1.json" <<'EOF'
{"total_count":2,"check_runs":[{"id":1,"name":"ci-ok","status":"completed","conclusion":"success"},{"id":2,"name":"ci-ok","status":"completed","conclusion":"failure"}]}
EOF
    cat >"$dir_e2/1.json" <<'EOF'
{"total_count":2,"check_runs":[{"id":2,"name":"ci-ok","status":"completed","conclusion":"failure"},{"id":1,"name":"ci-ok","status":"completed","conclusion":"success"}]}
EOF
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_e1"
    local e1_rc="$WAIT_RC" e1_concl="$WAIT_CONCLUSION" e1_gh="$WAIT_GH_CALLS" e1_sl="$WAIT_SLEEP_CALLS"
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_e2"
    local e2_rc="$WAIT_RC" e2_concl="$WAIT_CONCLUSION" e2_gh="$WAIT_GH_CALLS" e2_sl="$WAIT_SLEEP_CALLS"
    if [[ "$e1_rc" -eq 0 && "$e1_concl" == "failure" && "$e1_gh" -eq 1 && "$e1_sl" -eq 0 \
      && "$e2_rc" -eq 0 && "$e2_concl" == "failure" && "$e2_gh" -eq 1 && "$e2_sl" -eq 0 ]]; then
      pass "$c_wait_e"
    else
      fail "$c_wait_e (asc=$e1_rc/$e1_concl/$e1_gh/$e1_sl desc=$e2_rc/$e2_concl/$e2_gh/$e2_sl [want 0/failure/1/0]; err=$(cat "$WAIT_ERR_FILE" 2>/dev/null || true))"
    fi

    # Case f: gh call names the stub head SHA and check_name=ci-ok, and GH_TOKEN equals the github.token stub.
    run_wait_step "$wf_env" "$job_env" "$wait_env" "$wait_run" "$dir_a"
    local f_errs="" call_args call_tok
    if [[ "$WAIT_GH_CALLS" -lt 1 ]]; then
      f_errs="${f_errs} gh was not called;"
    else
      while IFS= read -r call_args; do
        if ! grep -Eq "commits/${STUB_WAIT_HEAD_SHA}/check-runs([?[:space:]]|$)" <<<"$call_args"; then
          f_errs="${f_errs} gh args missing commits/${STUB_WAIT_HEAD_SHA}/check-runs (got: $call_args);"
        fi
        if ! grep -Eq '(^|[?&[:space:]])check_name=ci-ok([&[:space:]]|$)' <<<"$call_args"; then
          f_errs="${f_errs} gh args missing check_name=ci-ok (got: $call_args);"
        fi
      done <"$WAIT_GH_ARGS_FILE"
      while IFS= read -r call_tok; do
        if [[ "$call_tok" != "$STUB_WAIT_GH_TOKEN" ]]; then
          f_errs="${f_errs} GH_TOKEN=${call_tok:-<unset>} (want $STUB_WAIT_GH_TOKEN);"
        fi
      done <"$WAIT_GH_TOKENS_FILE"
    fi
    if [[ -z "$f_errs" ]]; then
      pass "$c_wait_f"
    else
      fail "$c_wait_f ($f_errs)"
    fi
  fi

  # 5f. Mint CI App token
  local mint_id=""
  if [[ "$mint_idx" -eq 0 ]]; then
    fail "$c_mint (no actions/create-github-app-token step)"
  else
    local mint_step mint_uses mint_with app_id priv_key mint_errs=""
    mint_step="$(cat "$steps_dir/$mint_idx")"
    mint_uses="$(extract_scalar_or_block_field "$mint_step" uses)"
    mint_id="$(extract_scalar_or_block_field "$mint_step" id)"
    mint_with="$(extract_mapping_from_block "$mint_step" with)"
    app_id="$(map_get "$mint_with" app-id)"
    priv_key="$(map_get "$mint_with" private-key)"

    if [[ "$mint_count" -gt 1 ]]; then
      mint_errs="${mint_errs} expected 1 create-github-app-token step, found $mint_count;"
    fi
    if [[ "$mint_uses" != "$PINNED_APP_TOKEN_ACTION" ]]; then
      mint_errs="${mint_errs} uses=$mint_uses (want $PINNED_APP_TOKEN_ACTION);"
    fi
    if ! is_gha_expr "$app_id" "vars.CI_APP_ID"; then
      mint_errs="${mint_errs} app-id=$app_id (want \${{ vars.CI_APP_ID }});"
    fi
    if ! is_gha_expr "$priv_key" "secrets.CI_APP_PRIVATE_KEY"; then
      mint_errs="${mint_errs} private-key=$priv_key (want \${{ secrets.CI_APP_PRIVATE_KEY }});"
    fi
    if [[ -z "$mint_id" ]]; then
      mint_errs="${mint_errs} mint step has no id;"
    fi

    local expected_mint_perms actual_mint_perms
    expected_mint_perms="$(printf '%s\n%s' \
      "permission-contents=write" \
      "permission-pull-requests=write")"
    actual_mint_perms="$(grep '^permission-' <<<"$mint_with" | LC_ALL=C sort || true)"
    if [[ "$actual_mint_perms" != "$expected_mint_perms" ]]; then
      mint_errs="${mint_errs} permission-*=[$(tr '\n' ' ' <<<"$actual_mint_perms")] (want [$(tr '\n' ' ' <<<"$expected_mint_perms")]);"
    fi

    if ! expr_requires "$mint_if" "$ci_ok_re"; then
      mint_errs="${mint_errs} mint step if does not require steps.ci_ok.outputs.conclusion == 'success' (got: ${mint_if:-<unset>});"
    fi

    if [[ -z "$mint_errs" ]]; then
      pass "$c_mint"
    else
      fail "$c_mint ($mint_errs)"
    fi
  fi

  # 5g. Merge step: requires ci_ok success, passes --squash and --match-head-commit,
  # uses CI App token, and no step anywhere uses --auto.
  local merge_errs=""
  if [[ -z "$merge_indices" ]]; then
    merge_errs="${merge_errs} no gh pr merge command found;"
  else
    local midx merge_step step_merge_if merge_run merge_clean merge_env cmd_line
    for midx in $merge_indices; do
      merge_step="$(cat "$steps_dir/$midx")"
      step_merge_if="$(extract_scalar_or_block_field "$merge_step" if)"
      merge_run="$(extract_run_body "$merge_step")"
      merge_clean="$(join_continuations "$(strip_shell_comments "$merge_run")")"
      merge_env="$(extract_mapping_from_block "$merge_step" env)"

      if ! expr_requires "$step_merge_if" "$ci_ok_re"; then
        merge_errs="${merge_errs} merge step $midx if does not require steps.ci_ok.outputs.conclusion == 'success' (got: ${step_merge_if:-<unset>});"
      fi

      while IFS= read -r cmd_line; do
        if grep -Eq "$merge_cmd_re" <<<"$cmd_line"; then
          if ! grep -Eq '(^|[[:space:]])--squash([[:space:];&|)]|$)' <<<"$cmd_line"; then
            merge_errs="${merge_errs} step $midx gh pr merge does not pass --squash;"
          fi
          if ! merge_cmd_has_match_head_commit "$cmd_line" "$merge_env" "$job_env" "$wf_env"; then
            merge_errs="${merge_errs} step $midx gh pr merge does not pass --match-head-commit with PR head SHA;"
          fi
        fi
      done < <(split_shell_commands "$merge_clean")

      if [[ -n "$mint_id" ]]; then
        if [[ "$mint_idx" -ge "$midx" ]]; then
          merge_errs="${merge_errs} CI App token mint step must precede merge step $midx;"
        fi
        if ! merge_step_uses_token "$merge_env" "$job_env" "$merge_clean" "$mint_id"; then
          merge_errs="${merge_errs} merge step $midx does not pass \${{ steps.${mint_id}.outputs.token }} as GH_TOKEN/GITHUB_TOKEN;"
        fi
      else
        merge_errs="${merge_errs} merge step $midx cannot use CI App token (no mint step with id);"
      fi
    done
  fi

  # Never use --auto anywhere in any step's active run script.
  local any_auto=0
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    run_body="$(extract_run_body "$step_text")"
    run_clean="$(join_continuations "$(strip_shell_comments "$run_body")")"
    if grep -Eq '(^|[[:space:]])--auto([[:space:];&|)]|$)' <<<"$run_clean"; then
      any_auto=1
      break
    fi
  done
  if [[ "$any_auto" -eq 1 ]]; then
    merge_errs="${merge_errs} uses --auto (amended C3 requires direct merge, never --auto);"
  fi

  if [[ -z "$merge_errs" ]]; then
    pass "$c_merge"
  else
    fail "$c_merge ($merge_errs)"
  fi
}

check_dependabot_automerge

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
