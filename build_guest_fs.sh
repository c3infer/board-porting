#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
DEBOS="$BOARD/debos-fs"

if [[ ! -x "$DEBOS/build.sh" ]]; then
    echo "Missing $DEBOS/build.sh; run repo sync first" >&2
    exit 1
fi

cd "$DEBOS"
./build.sh --format ext4 --imgname guest-fs.img --imgsize 2300MB \
    --overlay-dest / --console hvc0 --py-enable 1 \
    --reqs-file ./requirements.txt --custom-script ./script.sh --memory 4Gb
