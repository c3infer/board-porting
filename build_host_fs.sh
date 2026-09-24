#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
RECIPES="$BOARD/debian-image-recipes"
SNAPSHOT="$BOARD/snapshot"
GUEST_FS="$BOARD/debos-fs/out/guest-fs.img"
OVERLAY="$RECIPES/overlays/board-porting"
PREBUILT="$RECIPES/prebuilt"

for source in "$GUEST_FS" "$SNAPSHOT/Image-guest" \
    "$SNAPSHOT/idbloader.img" "$SNAPSHOT/u-boot.itb" \
    "$SNAPSHOT/lkvm" \
    "$BOARD/opencca-assets/rk3588/rk3588_spl_loader_v1.08.111.bin" \
    "$RECIPES/opencca-image-rockchip-rk3588.yaml"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing $source; build the board and guest filesystem first" >&2
        exit 1
    fi
done

mapfile -t kernel_packages < <(find "$BOARD/linux-release" -type f \
    -name 'linux-image-*_arm64.deb' ! -name '*-dbg_*' | sort)
if (( ${#kernel_packages[@]} == 0 )); then
    echo "No host linux-image .deb found in $BOARD/linux-release" >&2
    exit 1
fi

mkdir -p "$OVERLAY/disks" "$PREBUILT/linux" \
    "$PREBUILT/u-boot-rock5b-rk3588" "$RECIPES/out"
cp "$GUEST_FS" "$OVERLAY/disks/guest-fs.img"
cp "$SNAPSHOT/Image-guest" "$OVERLAY/disks/Image"
cp "$SNAPSHOT/lkvm" "$OVERLAY/lkvm"
cp "${kernel_packages[-1]}" "$PREBUILT/linux/"
cp "$SNAPSHOT/idbloader.img" "$SNAPSHOT/u-boot.itb" \
    "$PREBUILT/u-boot-rock5b-rk3588/"
cp "$BOARD/opencca-assets/rk3588/rk3588_spl_loader_v1.08.111.bin" \
    "$PREBUILT/u-boot-rock5b-rk3588/"

python3 "$ROOT/scripts/prepare-host-recipe.py" \
    "$RECIPES/opencca-image-rockchip-rk3588.yaml" \
    "$RECIPES/board-porting-image.yaml"

cd "$RECIPES"
if [[ ! -f out/ospack-debian-arm64-trixie.tar.gz ]]; then
    debos --artifactdir=out -t architecture:arm64 opencca-ospack-debian.yaml
fi
debos --artifactdir=out -t architecture:arm64 \
    -t platform:rock5b-rk3588 board-porting-image.yaml
