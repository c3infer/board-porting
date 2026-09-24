#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/board"}
cd "$BOARD"
make -f opencca-build/docker/Makefile build
make -f opencca-build/docker/Makefile start
make -f opencca-build/docker/Makefile enter
