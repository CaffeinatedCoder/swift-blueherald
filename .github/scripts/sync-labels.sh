#!/usr/bin/env bash
# Creates or updates the repository's labels from .github/labels.json, so a new fork or a renamed
# repository has the scheme CONTRIBUTING.md#issues describes. Labels the file does not name are left
# alone. Needs `gh` signed in and `jq`.
#   .github/scripts/sync-labels.sh [--dry-run] [owner/repo]
set -euo pipefail

dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
repo=${1:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
labels="$here/../labels.json"

jq -c '.[]' "$labels" | while read -r label; do
  name=$(jq -r .name <<<"$label")
  color=$(jq -r .color <<<"$label")
  description=$(jq -r .description <<<"$label")
  if (( dry )); then
    printf '%-20s #%s  %s\n' "$name" "$color" "$description"
  else
    gh label create "$name" --color "$color" --description "$description" --force ${repo:+--repo "$repo"}
  fi
done
