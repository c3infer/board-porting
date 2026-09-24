#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
DEBOS="$BOARD/debos-fs"
OVERLAY="$DEBOS/board-porting-overlay"

if [[ ! -x "$DEBOS/build.sh" ]]; then
    echo "Missing $DEBOS/build.sh; run repo sync first" >&2
    exit 1
fi

command -v aarch64-linux-gnu-gcc >/dev/null || {
    echo "Missing aarch64-linux-gnu-gcc (available in the build container)" >&2
    exit 1
}
mkdir -p "$OVERLAY"
cp -a "$ROOT/microbenchmark/." "$OVERLAY/"
aarch64-linux-gnu-gcc -O2 -Wall \
    -o "$OVERLAY/rw_ivshmem" "$ROOT/microbenchmark/rw_ivshmem.c"

cd "$DEBOS"
# The benchmark uses shell tools. Avoid the upstream custom script, which
# requires an autorun.service that this image does not provide.
./build.sh --format ext4 --imgname guest-fs.img --imgsize 2300MB \
    --overlay ./board-porting-overlay --overlay-dest /root \
    --console hvc0 --py-enable 0 --memory 4Gb
