#!/usr/bin/env bash
# Checks a pull_request event payload against the tracking rules in CONTRIBUTING.md#issues:
# exactly one type label, a severity on a bug, and a closing reference to the issue it resolves.
# Needs no token and runs locally on a saved event:
#   .github/scripts/pr-hygiene.sh path/to/event.json
set -euo pipefail

event=${1:?usage: pr-hygiene.sh <event.json>}
author=$(jq -r '.pull_request.user.login' "$event")
labels=$(jq -r '.pull_request.labels[].name' "$event")
body=$(jq -r '.pull_request.body // ""' "$event")

# Dependabot opens its own PRs with its own labels; they close no issue.
if [[ $author == "dependabot[bot]" ]]; then
  echo "Dependabot PR, not checked."
  exit 0
fi

problems=()

types=$(grep -cxE 'bug|enhancement|documentation|tests|chore' <<<"$labels" || true)
if (( types != 1 )); then
  problems+=("Needs exactly one type label (bug, enhancement, documentation, tests, chore); it has $types.")
fi

if grep -qx bug <<<"$labels" && ! grep -q '^severity/' <<<"$labels"; then
  problems+=("A bug needs a severity/* label (critical, high, medium, low).")
fi

# GitHub's closing keywords, with #n or owner/repo#n. Only these link the PR to its issue.
closing='\b(close[sd]?|fix(e[sd])?|resolve[sd]?):? +([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+'
if ! grep -qiE "$closing" <<<"$body"; then
  problems+=("The description needs a closing reference to its issue, such as 'Closes #12'.")
fi

if (( ${#problems[@]} )); then
  printf '::error::%s\n' "${problems[@]}"
  echo "See the label legend in CONTRIBUTING.md#issues."
  exit 1
fi
echo "Labels and issue link are in order."
