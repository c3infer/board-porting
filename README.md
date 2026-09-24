# board-porting

Reproducible Radxa Rock 5B board build using C3Infer's canonical host kernel,
guest kernel, QEMU VMM, and RMM repositories. The manifest is a lockfile: all
projects are pinned to immutable commits.

## Bootstrap

The repository is usable locally after its first commit:

```sh
mkdir caec-radxa && cd caec-radxa
repo init -u file:///home/amir/mica/board-porting -m manifest-local.xml
repo sync -j8 --no-clone-bundle
./board/manifest/prebuild.sh
```

For a hosted version, replace the `file://` URL with the SSH URL of this
repository and use `manifest-radxa.xml` after replacing its self-project URL
with the hosted repository name. `repo sync` needs GitHub SSH access for the
C3Infer projects.

## Build and deploy

Start the container:

```sh
./board/manifest/container.sh
```

Inside it:

```sh
./manifest/scripts/build-board.sh all
./manifest/scripts/provenance.sh
./manifest/build_guest_fs.sh
./manifest/build_host_fs.sh
```

The guest script builds `debos-fs/out/guest-fs.img` with the CAEC realm
microbenchmark under `/root/usecases/rg_rn_re`. It omits the upstream optional
custom script, which expects an `autorun.service` absent from this overlay.
The host script stages that image, `snapshot/Image-guest`, `lkvm`, and the
locally built `qemu-system-aarch64` under
`/home/user` in the Radxa image. It invokes the pinned Debos recipe with an
8 GB image size. Its generated ospack recipe uses Debian repositories because
the pinned Collabora signing key fails current Debian verification. The result is
`debian-image-recipes/out/opencca-image-rockchip-rock5b-rk3588.img.gz` and a
matching `.bmap`. Run the two scripts in order after the board build.
The host base image omits optional Rockchip graphics packages; the realm
microbenchmark does not need them.

Outside it, write the SD card only after checking the target with `lsblk`, then
flash a Maskrom-mode board:

```sh
sudo bmaptool copy board/debian-image-recipes/out/opencca-image-rockchip-rock5b-rk3588.img.gz /dev/sdX
sudo ./board/opencca-flash/flash/flash.sh spi
```

## Patches

No historical CAEC patch is applied implicitly. First move a patch into the
matching upstream C3Infer repository whenever possible. For a required local
patch, add it below `patches/`, copy `series.conf.example` to `series.conf`,
and declare the precise base SHA. `prebuild.sh` refuses to apply a series to a
different base.

## Current scope

The four C3Infer sources are pinned to their current public HEAD commits. The
firmware/image support projects use the known Rock 5B pins from the working
Diode-CCA-derived board flow. A clean build will decide whether the C3Infer
guest kernel already absorbs the CAEC guest patch series; if it does not, add
only the still-required patches through the guarded patch mechanism above.
