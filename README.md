# board-porting

Radxa Rock 5B build using C3Infer's host kernel, guest kernel, QEMU VMM, and
RMM repositories. The kernels, QEMU, and RMM are pinned to immutable commits;
TF-A and U-Boot track OpenCCA's matching `opencca/systex25` branches. The
manifest project itself follows the published `main` branch.

## Bootstrap

Initialize the workspace from the published repository:

```sh
mkdir caec-radxa && cd caec-radxa
repo init -u git@github.com:c3infer/board-porting.git -m manifest-radxa.xml
repo sync -j8 --no-clone-bundle
./board/manifest/prebuild.sh
```
`repo sync` requires GitHub SSH access for the C3Infer projects.

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

## Deploy to the board

Exit the build container. Check the target device with `lsblk`, write the SD
card, then put the Radxa in Maskrom mode and flash SPI firmware:

```sh
sudo bmaptool copy board/debian-image-recipes/out/opencca-image-rockchip-rock5b-rk3588.img.gz /dev/sdX
sudo ./board/opencca-flash/flash/flash.sh spi
```

Replace `/dev/sdX` with the complete SD-card block-device path. Boot the Radxa
from that SD card before running any benchmark command below.

## Run the benchmark on the board

After the SD card and SPI setup above, log in to the booted Radxa as `user`.
Run the benchmark on the board itself:

```sh
python3 /home/user/microbenchmark/run.py all --trials 20 --iters 20
```

<!-- If a trial fails, its CSV row contains an error status and the corresponding
console log is retained. The image contains a generated benchmark key shared
by the three guest disks for the two encrypted modes. It is a test key, not a
secret credential. The runner needs root access to QEMU KVM, the realm console
sockets, and `/dev/shm`; use `sudo` if the `user` account lacks that access. -->

<!-- ## Patches

`prebuild.sh` applies the patch listed in `patches/series.conf` to the pinned
`opencca-flash` checkout. It adds a five-second timeout to the loader
capability probe so `flash.sh spi` proceeds to transfer the SPL when `rcb`
hangs in Maskrom mode. The patch is guarded by the exact upstream base SHA;
`prebuild.sh` stops if the checkout has moved to a different revision.

For any additional required local patch, add it below `patches/` and declare
its project, precise base SHA, and patch directory in `patches/series.conf`.

## Current scope

The four C3Infer sources are pinned to their current public HEAD commits. The
firmware/image support projects use the known Rock 5B pins from the working
Diode-CCA-derived board flow. A clean build will decide whether the C3Infer
guest kernel already absorbs the CAEC guest patch series; if it does not, add
only the still-required patches through the guarded patch mechanism above. -->
