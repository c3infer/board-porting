#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}

"$ROOT/scripts/verify-sources.sh"
exec "$BOARD/opencca-build/scripts/build_all.sh" "${1:-all}"
