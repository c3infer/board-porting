#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
DEBOS="$BOARD/debos-fs"
OVERLAY="$DEBOS/board-porting-overlay-v2"

if [[ ! -x "$DEBOS/build.sh" ]]; then
    echo "Missing $DEBOS/build.sh; run repo sync first" >&2
    exit 1
fi

command -v aarch64-linux-gnu-gcc >/dev/null || {
    echo "Missing aarch64-linux-gnu-gcc (available in the build container)" >&2
    exit 1
}
mkdir -p "$OVERLAY/root/microbenchmark" \
    "$OVERLAY/etc/systemd/system/multi-user.target.wants"
cp -a "$ROOT/microbenchmark/." "$OVERLAY/root/microbenchmark/"
aarch64-linux-gnu-gcc -O2 -Wall \
    -o "$OVERLAY/root/microbenchmark/rw_ivshmem" \
    "$ROOT/microbenchmark/rw_ivshmem.c"
openssl rand -hex 32 > "$OVERLAY/root/microbenchmark/benchmark.key"
chmod 0600 "$OVERLAY/root/microbenchmark/benchmark.key"
cp "$ROOT/microbenchmark/microbenchmark-ready.service" \
    "$OVERLAY/etc/systemd/system/"
ln -sfn ../microbenchmark-ready.service \
    "$OVERLAY/etc/systemd/system/multi-user.target.wants/microbenchmark-ready.service"
python3 "$ROOT/scripts/prepare-guest-recipe.py" \
    "$DEBOS/recipe.yaml" "$DEBOS/board-porting-recipe.yaml"

cd "$DEBOS"
# The benchmark uses shell tools. Avoid the upstream custom script, which
# requires an autorun.service that this image does not provide.
RECIPE=./board-porting-recipe.yaml ./build.sh \
    --format ext4 --imgname guest-fs.img --imgsize 2300MB \
    --overlay ./board-porting-overlay-v2 --overlay-dest / \
    --console hvc0 --py-enable 0 --memory 4Gb
