#!/usr/bin/env bash
# Print the stacks a deploy target supports, from its target.yml `stacks:`
# list, space-separated. Prints nothing when the list is absent, which means
# every stack. Used by bootstrap.sh and bootstrap-target.sh.
#
# Usage: scripts/target-stacks.sh <path/to/target.yml>
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: scripts/target-stacks.sh <target.yml>" >&2; exit 64; }
[[ -f "$1" ]] || { echo "target-stacks: no such file: $1" >&2; exit 64; }
sed -n '/^stacks:/,/^[^[:space:]-]/p' "$1" |
  sed -n 's/^[[:space:]]*-[[:space:]]*\([a-z0-9-]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//'
