#!/usr/bin/env bash
# Print the commit to classify a main-branch deploy against (spec §4.10).
#
# Usage: scripts/deploy-base.sh <head-sha>
# Env:   GITHUB_REPOSITORY (owner/name), GH_TOKEN (read access to deployments)
#
# Prints the SHA of the newest *successful* production deployment when it is
# an ancestor of <head-sha>, or nothing when there is none (never deployed,
# or history was rewritten). The caller treats nothing as "classify as code".
#
# Why not HEAD~1: deploy.yml runs one deploy at a time, and GitHub cancels a
# *pending* run when a newer one joins the group. If a code merge's run is
# cancelled that way and the next merge is docs-only, HEAD~1..HEAD would
# classify as docs and the code would never deploy. Classifying from the last
# real production deploy covers every commit since.
set -euo pipefail

head="${1:-}"
[[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || { echo "deploy-base: invalid head sha: ${head:-<empty>}" >&2; exit 64; }
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "deploy-base: GITHUB_REPOSITORY is not set" >&2; exit 64; }

# Newest first. A failure to read is an error: guessing could skip a deploy.
# One page is enough: if the 30 newest all failed, nothing is printed and the
# caller classifies as code, which deploys rather than skips.
deployments="$(gh api "repos/$repo/deployments?environment=production&per_page=30")" ||
  { echo "deploy-base: cannot read deployments of $repo" >&2; exit 1; }

while IFS=$'\t' read -r id sha; do
  [[ "$id" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  statuses="$(gh api "repos/$repo/deployments/$id/statuses?per_page=1")" ||
    { echo "deploy-base: cannot read the status of deployment $id" >&2; exit 1; }
  state="$(jq -r '.[0].state // ""' <<<"$statuses")"
  [[ "$state" == success ]] || continue
  if git merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
    printf '%s\n' "$sha"
  fi
  exit 0
done < <(jq -r '.[] | "\(.id)\t\(.sha)"' <<<"$deployments")
