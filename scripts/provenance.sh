#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/board"}
OUT=${1:-"$BOARD/snapshot/build-provenance.tsv"}
mkdir -p "$(dirname -- "$OUT")"

{
  printf 'generated_utc\t%s\n' "$(date -u +%FT%TZ)"
  printf 'component\tcommit\torigin\n'
  for tree in "$BOARD"/*; do
    [[ -e "$tree/.git" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "$tree")" \
      "$(git -C "$tree" rev-parse HEAD)" \
      "$(git -C "$tree" remote get-url origin 2>/dev/null || true)"
  done
} > "$OUT"
echo "Wrote $OUT"
