#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOARD=${BOARD_ROOT:-"$ROOT/.."}

required=(linux linux-guest qemu-vmm tf-rmm trusted-firmware-a u-boot rkbin debos-fs debian-image-recipes opencca-build opencca-flash kvmtool External_modules)
for project in "${required[@]}"; do
  test -e "$BOARD/$project/.git" || {
    echo "Missing $BOARD/$project; run repo sync first." >&2
    exit 1
  }
done

"$ROOT/scripts/verify-sources.sh"

cd "$BOARD/tf-rmm"
git submodule update --init --recursive

if [[ -x "$BOARD/debian-image-recipes/download-rock5b-artifacts.sh" ]]; then
  "$BOARD/debian-image-recipes/download-rock5b-artifacts.sh"
fi

mkdir -p "$BOARD/snapshot" "$BOARD/tmp" "$BOARD/debos-fs/overlay" \
  "$BOARD/debian-image-recipes/out" \
  "$BOARD/debian-image-recipes/overlays/CAEC/VM_image" \
  "$BOARD/debian-image-recipes/overlays/CAEC/shared_with_VM"

# Patch series are intentionally opt-in. Add a series and its expected base to
# patches/series.conf, then use scripts/apply-patches.sh to apply it.
if [[ -f "$ROOT/patches/series.conf" ]]; then
  "$ROOT/scripts/apply-patches.sh"
fi

echo "Board source preparation complete: $BOARD"
