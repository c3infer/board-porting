#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/board"}

declare -A pins=(
  [linux]=7d5e91cae4ad6ab8fcc89d54a9a054d27972cb00
  [linux-guest]=d327b9c9569cb41652f7e5c00e0257540793ee8b
  [qemu-vmm]=aee77fb938065b6db056eebf47cf91f570b3648c
  [tf-rmm]=e541593ef36a88403497b639b0ba803e66d35e7a
)

status=0
for project in "${!pins[@]}"; do
  tree="$BOARD/$project"
  if [[ ! -e "$tree/.git" ]]; then
    echo "ERROR: missing checkout: $tree" >&2
    status=1
    continue
  fi
  head=$(git -C "$tree" rev-parse HEAD)
  if [[ "$head" != "${pins[$project]}" ]]; then
    echo "ERROR: $project is $head; expected ${pins[$project]}" >&2
    status=1
  fi
  if [[ -n $(git -C "$tree" status --porcelain --untracked-files=no) ]]; then
    echo "ERROR: $project has tracked working-tree changes" >&2
    status=1
  fi
done

exit "$status"
