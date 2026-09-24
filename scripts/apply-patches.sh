#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
CONF="$ROOT/patches/series.conf"

# Format: project|base-commit|relative-patch-directory
while IFS='|' read -r project base patch_dir; do
  [[ -z "${project}" || "${project}" == \#* ]] && continue
  tree="$BOARD/$project"
  patches=("$ROOT/patches/$patch_dir"/*.patch)
  [[ -e "${patches[0]}" ]] || { echo "No patches for $project" >&2; exit 1; }
  actual=$(git -C "$tree" rev-parse HEAD)
  if [[ "$actual" != "$base" ]]; then
    already_applied=true
    for patch in "${patches[@]}"; do
      if ! git -C "$tree" apply --reverse --check "$patch"; then
        already_applied=false
        break
      fi
    done
    if [[ "$already_applied" == true ]]; then
      echo "$project patch series is already applied."
      continue
    fi
  fi
  [[ "$actual" == "$base" ]] || {
    echo "$project is $actual, but patch series requires $base" >&2
    exit 1
  }
  git -C "$tree" am "${patches[@]}"
done < "$CONF"
