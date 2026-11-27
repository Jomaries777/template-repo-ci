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

# --- Requirement 5: dependabot-automerge.yml (FR-8, C2, S1/C3 fallback) ------

# extract_workflow_run_list <file> <key>:
# Extracts items of `on.workflow_run.<key>` (inline `[a, b]` or block `- a`).
extract_workflow_run_list() {
  local file="$1" key="$2"
  extract_top_section "$file" on | awk -v target="$key" '
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
      if (on_ind == "") on_ind = ind
      if (!in_wr) {
        if (ind == on_ind && $0 ~ /^[ \t]*workflow_run:[ \t]*(#.*)?$/) {
          in_wr = 1
          wr_ind = ind
        }
        next
      }
      if (ind <= wr_ind) exit
      if (wr_child_ind == "") wr_child_ind = ind
      if (!in_key) {
        if (ind == wr_child_ind && $0 ~ ("^[ \t]*" target ":([ \t]|$)")) {
          val = substr($0, ind + length(target) + 2)
          sub(/^[ \t]+/, "", val)
          sub(/[ \t]+#.*$/, "", val)
          sub(/[ \t]+$/, "", val)
          if (val == "") {
            in_key = 1
            key_ind = ind
            next
          }
          if (substr(val, 1, 1) == "[" && substr(val, length(val), 1) == "]") {
            inner = substr(val, 2, length(val) - 2)
            n = split(inner, parts, ",")
            for (i = 1; i <= n; i++) {
              item = clean(parts[i])
              if (item != "") print item
            }
          } else {
            item = clean(val)
            if (item != "") print item
          }
          exit
        }
        next
      }
      if (ind < key_ind || (ind == key_ind && $0 !~ /^[ \t]*-[ \t]/)) exit
      if ($0 ~ /^[ \t]*-[ \t]/) {
        item = $0
        sub(/^[ \t]*-[ \t]+/, "", item)
        item = clean(item)
        if (item != "") print item
      }
    }
  '
}

# on_has_event <file> <event_name>: true if `on:` triggers on <event_name>.
on_has_event() {
  local file="$1" ev="$2"
  extract_top_section "$file" on | awk -v target="$ev" '
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (on_ind == "") on_ind = ind
      if (ind == on_ind && $0 ~ ("^[ \t]*" target ":([ \t]|$)")) {
        found = 1
        exit
      }
    }
    END { exit (found ? 0 : 1) }
  '
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

check_dependabot_automerge() {
  local c_mint="dependabot-automerge: mints CI App token with pinned action and CI_APP_*"
  local c_trig="dependabot-automerge: runs on workflow_run of CI workflow with success conclusion"
  local c_actor="dependabot-automerge: requires actor to be dependabot[bot]"
  local c_author="dependabot-automerge: requires PR author to be dependabot[bot]"
  local c_merge="dependabot-automerge: merges with gh pr merge --squash and never --auto"

  local file="$workflows/dependabot-automerge.yml"
  if [[ ! -f "$file" ]]; then
    fail "$c_mint (missing file: $file)"
    fail "$c_trig (missing file: $file)"
    fail "$c_actor (missing file: $file)"
    fail "$c_author (missing file: $file)"
    fail "$c_merge (missing file: $file)"
    return
  fi

  local ci_name="pr"
  if [[ -f "$workflows/pr.yml" ]]; then
    local parsed_name
    parsed_name="$(extract_top_scalar "$workflows/pr.yml" name)"
    if [[ -n "$parsed_name" ]]; then ci_name="$parsed_name"; fi
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
    fail "$c_mint (no job found in $file)"
    fail "$c_trig (no job found in $file)"
    fail "$c_actor (no job found in $file)"
    fail "$c_author (no job found in $file)"
    fail "$c_merge (no job found in $file)"
    return
  fi

  local steps_dir="$tmp/steps_dep"
  local nsteps i step_text uses run_body run_clean
  nsteps="$(split_job_steps "$job_block" "$steps_dir")"

  local merge_cmd_re='(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|)]|$)'
  local mint_idx=0 mint_count=0 merge_idx=0 merge_indices=""
  for ((i = 1; i <= nsteps; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    uses="$(extract_scalar_or_block_field "$step_text" uses)"
    case "$uses" in
      actions/create-github-app-token | actions/create-github-app-token@*)
        mint_count=$((mint_count + 1))
        if [[ "$mint_idx" -eq 0 ]]; then mint_idx=$i; fi
        ;;
    esac
    run_body="$(extract_run_body "$step_text")"
    run_clean="$(join_continuations "$(strip_shell_comments "$run_body")")"
    if grep -Eq "$merge_cmd_re" <<<"$run_clean"; then
      if [[ "$merge_idx" -eq 0 ]]; then merge_idx=$i; fi
      merge_indices="${merge_indices} ${i}"
    fi
  done

  # 5a. Mint CI App token
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
    # If permission-* inputs are explicitly provided, allow only contents/pull-requests write.
    local extra_perms
    extra_perms="$(grep '^permission-' <<<"$mint_with" | grep -Ev '^permission-(contents|pull-requests)=write$' || true)"
    if [[ -n "$extra_perms" ]]; then
      mint_errs="${mint_errs} unexpected permission-* inputs: $(tr '\n' ' ' <<<"$extra_perms");"
    fi

    if [[ -z "$mint_errs" ]]; then
      pass "$c_mint"
    else
      fail "$c_mint ($mint_errs)"
    fi
  fi

  # Collect job `if:` and mint/merge step `if:`s for trigger/actor/author checks.
  local job_if mint_if="" merge_if=""
  job_if="$(extract_scalar_or_block_field "$job_block" if)"
  if [[ "$mint_idx" -gt 0 ]]; then
    mint_if="$(extract_scalar_or_block_field "$(cat "$steps_dir/$mint_idx")" if)"
  fi
  if [[ "$merge_idx" -gt 0 ]]; then
    merge_if="$(extract_scalar_or_block_field "$(cat "$steps_dir/$merge_idx")" if)"
  fi

  local has_workflow_run=0
  if on_has_event "$file" workflow_run; then
    has_workflow_run=1
  fi

  # 5b. workflow_run trigger of CI workflow with success conclusion
  local trig_errs=""
  if [[ "$has_workflow_run" -ne 1 ]]; then
    trig_errs="${trig_errs} on: does not trigger on workflow_run;"
  else
    local wr_workflows wr_types
    wr_workflows="$(extract_workflow_run_list "$file" workflows)"
    wr_types="$(extract_workflow_run_list "$file" types)"
    if [[ "$wr_workflows" != "$ci_name" ]]; then
      trig_errs="${trig_errs} workflow_run.workflows=[$(tr '\n' ',' <<<"$wr_workflows")] (want [$ci_name]);"
    fi
    if ! grep -Fxq "completed" <<<"$wr_types"; then
      trig_errs="${trig_errs} workflow_run.types=[$(tr '\n' ',' <<<"$wr_types")] (must include completed);"
    fi
  fi
  if on_has_event "$file" pull_request || on_has_event "$file" pull_request_target; then
    trig_errs="${trig_errs} on: must not trigger on pull_request/pull_request_target;"
  fi

  local concl_re="github\.event\.workflow_run\.conclusion[[:space:]]*==[[:space:]]*['\"]success['\"]|['\"]success['\"][[:space:]]*==[[:space:]]*github\.event\.workflow_run\.conclusion"
  local has_concl=0
  if expr_requires "$job_if" "$concl_re"; then
    has_concl=1
  elif [[ "$mint_idx" -gt 0 && "$merge_idx" -gt 0 ]] \
    && expr_requires "$mint_if" "$concl_re" \
    && expr_requires "$merge_if" "$concl_re"; then
    has_concl=1
  fi
  if [[ "$has_concl" -ne 1 ]]; then
    trig_errs="${trig_errs} missing github.event.workflow_run.conclusion == 'success' gate;"
  fi

  if [[ -z "$trig_errs" ]]; then
    pass "$c_trig"
  else
    fail "$c_trig ($trig_errs)"
  fi

  # 5c. Actor must be dependabot[bot] (C2)
  local actor_re="(github\.(triggering_)?actor|github\.event\.workflow_run\.(triggering_)?actor\.login)[[:space:]]*==[[:space:]]*['\"]dependabot\[bot\]['\"]|['\"]dependabot\[bot\]['\"][[:space:]]*==[[:space:]]*(github\.(triggering_)?actor|github\.event\.workflow_run\.(triggering_)?actor\.login)"
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
    fail "$c_actor (missing actor == 'dependabot[bot]' gate in job/step if)"
  fi

  # 5d. PR author must be dependabot[bot] (C2)
  # On `workflow_run`, `github.event.pull_request` does not exist, so accept either:
  # - a `run:` step (at or before the merge step) querying PR author and comparing to dependabot[bot] / app/dependabot,
  # - `gh pr list --author` / `-A` filtering for dependabot[bot] / app/dependabot, or
  # - a step querying PR author whose output is checked in merge_if against dependabot[bot] / app/dependabot.
  # On non-`workflow_run` (e.g. legacy pull_request trigger), also allow `github.event.pull_request.user.login`.
  local has_author=0
  if [[ "$has_workflow_run" -eq 0 ]]; then
    local pr_if_re="github\.event\.pull_request\.user\.login[[:space:]]*==[[:space:]]*['\"]dependabot\[bot\]['\"]|['\"]dependabot\[bot\]['\"][[:space:]]*==[[:space:]]*github\.event\.pull_request\.user\.login"
    if expr_requires "$job_if" "$pr_if_re"; then
      has_author=1
    fi
  fi

  local pre_limit="$nsteps"
  if [[ "$merge_idx" -gt 0 ]]; then pre_limit="$merge_idx"; fi
  local all_pre_run="" query_step_ids="" step_id
  for ((i = 1; i <= pre_limit; i++)); do
    step_text="$(cat "$steps_dir/$i")"
    step_id="$(extract_scalar_or_block_field "$step_text" id)"
    run_body="$(extract_run_body "$step_text")"
    run_clean="$(join_continuations "$(strip_shell_comments "$run_body")")"
    all_pre_run="${all_pre_run}"$'\n'"${run_clean}"
    if [[ -n "$step_id" ]] && grep -Eq '(\.user\.login|\.author\.login|--json([[:space:]]+|=)[^[:space:]]*author)' <<<"$run_clean"; then
      query_step_ids="${query_step_ids} ${step_id}"
    fi
  done

  if [[ "$has_author" -eq 0 ]]; then
    local queries_pr_author=0
    if grep -Eq '(\.user\.login|\.author\.login|--json([[:space:]]+|=)[^[:space:]]*author)' <<<"$all_pre_run"; then
      queries_pr_author=1
    fi
    if [[ "$queries_pr_author" -eq 1 ]]; then
      # Match ==, !=, ` = `, or bash `case` pattern matching dependabot[bot] / app/dependabot.
      if grep -Eq '(==|!=|[[:space:]]=[[:space:]])[[:space:]]*['\''"]?(dependabot\[bot\]|app/dependabot)['\''"]?|['\''"]?(dependabot\[bot\]|app/dependabot)['\''"]?[[:space:]]*(==|!=|[[:space:]]=[[:space:]])|(dependabot\\?\[bot\\?\]|app/dependabot)['\''"]?[[:space:]]*[|)]' <<<"$all_pre_run"; then
        has_author=1
      elif [[ "$mint_idx" -gt 0 && "$merge_idx" -gt 0 && -n "$query_step_ids" ]]; then
        local qid
        for qid in $query_step_ids; do
          local out_author_re="steps\.${qid}\.outputs\.[A-Za-z0-9_-]+[[:space:]]*==[[:space:]]*['\"](dependabot\[bot\]|app/dependabot)['\"]"
          if expr_requires "$merge_if" "$out_author_re"; then
            has_author=1
            break
          fi
        done
      fi
    elif grep -Eq 'gh[[:space:]]+pr[[:space:]]+list.*(--author|-A)([[:space:]]+|=)['\''"]?(dependabot\[bot\]|app/dependabot)['\''"]?' <<<"$all_pre_run"; then
      has_author=1
    fi
  fi

  if [[ "$has_author" -eq 1 ]]; then
    pass "$c_author"
  else
    fail "$c_author (missing PR author == dependabot[bot] check)"
  fi

  # 5e. Merges with `gh pr merge --squash` and never `--auto`, using the CI App token
  local merge_errs=""
  if [[ -z "$merge_indices" ]]; then
    merge_errs="${merge_errs} no gh pr merge command found;"
  else
    local job_env midx merge_step merge_run merge_clean merge_env cmd_line
    job_env="$(extract_mapping_from_block "$job_block" env)"
    for midx in $merge_indices; do
      merge_step="$(cat "$steps_dir/$midx")"
      merge_run="$(extract_run_body "$merge_step")"
      merge_clean="$(join_continuations "$(strip_shell_comments "$merge_run")")"
      merge_env="$(extract_mapping_from_block "$merge_step" env)"

      while IFS= read -r cmd_line; do
        if grep -Eq "$merge_cmd_re" <<<"$cmd_line"; then
          if ! grep -Eq '(^|[[:space:]])--squash([[:space:];&|)]|$)' <<<"$cmd_line"; then
            merge_errs="${merge_errs} step $midx gh pr merge does not pass --squash;"
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
    merge_errs="${merge_errs} uses --auto (S1/C3 requires direct merge, never --auto);"
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
