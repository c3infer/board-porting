#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
RECIPES="$BOARD/debian-image-recipes"
GUEST_FS="$BOARD/debos-fs/out/guest-fs.img"
GUEST_KERNEL="$BOARD/snapshot/Image-guest"

for source in "$GUEST_FS" "$GUEST_KERNEL" "$RECIPES/buildfs.sh"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing $source; build the board and guest filesystem first" >&2
        exit 1
    fi
done

DISKS="$RECIPES/overlays/mica/disks"
mkdir -p "$DISKS"
cp "$GUEST_FS" "$DISKS/guest-fs.img"
cp "$GUEST_KERNEL" "$DISKS/Image"

cd "$RECIPES"
./buildfs.sh
