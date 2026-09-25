#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}
RECIPES="$BOARD/debian-image-recipes"
SNAPSHOT="$BOARD/snapshot"
GUEST_FS="$BOARD/debos-fs/out/guest-fs.img"
OVERLAY="$RECIPES/overlays/board-porting-benchmark"
PREBUILT="$RECIPES/prebuilt"

for source in "$GUEST_FS" "$SNAPSHOT/Image-guest" \
    "$SNAPSHOT/idbloader.img" "$SNAPSHOT/u-boot.itb" \
    "$SNAPSHOT/lkvm" "$SNAPSHOT/qemu-system-aarch64" \
    "$BOARD/opencca-assets/rk3588/rk3588_spl_loader_v1.08.111.bin" \
    "$RECIPES/opencca-image-rockchip-rk3588.yaml"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing $source; build the board and guest filesystem first" >&2
        exit 1
    fi
done

host_image="$BOARD/linux/arch/arm64/boot/Image"
if [[ ! -f "$host_image" ]]; then
    echo "Missing host kernel build: $host_image" >&2
    exit 1
fi
host_hash=$(sha256sum "$host_image")
host_hash=${host_hash%% *}
mapfile -t kernel_packages < <(find "$BOARD/linux-release" -type f \
    -name 'linux-image-*_arm64.deb' ! -name '*-dbg_*' | sort)
host_package=
for package in "${kernel_packages[@]}"; do
    package_name=$(dpkg-deb -f "$package" Package)
    kernel_release=${package_name#linux-image-}
    if ! package_hash=$(dpkg-deb --fsys-tarfile "$package" |
        tar -xOf - "./boot/vmlinuz-$kernel_release" | sha256sum); then
        continue
    fi
    if [[ ${package_hash%% *} == "$host_hash" ]]; then
        host_package=$package
    fi
done
if [[ -z "$host_package" ]]; then
    echo "No host linux-image .deb matches $host_image in $BOARD/linux-release" >&2
    exit 1
fi
echo "Using host kernel package: $host_package"

mkdir -p "$OVERLAY/disks" "$OVERLAY/microbenchmark" "$PREBUILT/linux" \
    "$PREBUILT/u-boot-rock5b-rk3588" "$RECIPES/out"
for realm in realm1 realm2 realm3; do
    cp "$GUEST_FS" "$OVERLAY/disks/$realm.img"
done
cp "$SNAPSHOT/Image-guest" "$OVERLAY/disks/Image"
cp "$SNAPSHOT/lkvm" "$OVERLAY/lkvm"
cp "$SNAPSHOT/qemu-system-aarch64" "$OVERLAY/qemu-system-aarch64"
cp "$ROOT/host-microbenchmark/run.py" "$OVERLAY/microbenchmark/run.py"
cp "$host_package" "$PREBUILT/linux/"
cp "$SNAPSHOT/idbloader.img" "$SNAPSHOT/u-boot.itb" \
    "$PREBUILT/u-boot-rock5b-rk3588/"
cp "$BOARD/opencca-assets/rk3588/rk3588_spl_loader_v1.08.111.bin" \
    "$PREBUILT/u-boot-rock5b-rk3588/"

python3 "$ROOT/scripts/prepare-host-recipe.py" \
    "$RECIPES/opencca-image-rockchip-rk3588.yaml" \
    "$RECIPES/board-porting-image.yaml" \
    "$RECIPES/opencca-ospack-debian.yaml" \
    "$RECIPES/board-porting-ospack.yaml"

cd "$RECIPES"
if [[ ! -f out/ospack-debian-arm64-trixie.tar.gz ]]; then
    debos --artifactdir=out -t architecture:arm64 -t gfx:false \
        board-porting-ospack.yaml
fi
debos --artifactdir=out -t architecture:arm64 \
    -t platform:rock5b-rk3588 board-porting-image.yaml
