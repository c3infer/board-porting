# board-porting

Radxa Rock 5B build using C3Infer's host kernel, guest kernel, QEMU VMM, and
RMM repositories. The board stack is pinned to immutable commits. The manifest
project itself follows the published `main` branch.

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

The guest script builds `debos-fs/out/guest-fs.img` with the benchmark at
`/root/microbenchmark`. It installs OpenSSL for the CBC and CTR modes and
enables a boot-ready message on the `hvc0` console. It omits the upstream
optional custom script, which expects an absent `autorun.service`.

The host script makes **three full raw guest disks** from that image and
installs them at `/home/user/disks/realm1.img`, `realm2.img`, and `realm3.img`.
It also installs `snapshot/Image-guest`, `lkvm`, the locally built
`qemu-system-aarch64`, and `/home/user/microbenchmark/run.py`. The Radxa image
is 16 GB to hold all three disks. Its generated ospack recipe uses Debian
repositories because the pinned Collabora signing key fails current Debian
verification. The result is
`debian-image-recipes/out/opencca-image-rockchip-rock5b-rk3588.img.gz` and a
matching `.bmap`. Run the two scripts in order after the board build.
The host base image omits optional Rockchip graphics packages; the realm
microbenchmark does not need them.

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
Run the benchmark on the Radxa itself:

```sh
python3 /home/user/microbenchmark/run.py all --trials 20 --iters 20
```

The runner starts and stops QEMU realms for each trial. It measures boot time
from QEMU start to the guest's `MB_READY` console message. It measures policy
upload and attestation inside each guest. Attestation cases are realm1 with
policy, realm1 without policy, realm1 with realm2, and realm1 with realm2 and
realm3. Communication uses realm1 and realm2 with three modes: plain,
AES-256-CBC with HMAC, and AES-256-CTR with HMAC. The payload sizes are 64 KiB,
256 KiB, 512 KiB, 1 MiB, and 10 MiB. Each QEMU process uses one full raw disk;
no QCOW2 overlay is used.

CSV data and console logs go under `/home/user/microbenchmark/results/`.
`attestation.csv` records boot, policy upload, and attestation durations in
nanoseconds; `communication.csv` records round-trip times by mode and size.
The runner also writes PNG plots in `results/plots/`. To replot saved CSVs:

```sh
python3 /home/user/microbenchmark/run.py plot
```

If a trial fails, its CSV row contains an error status and the corresponding
console log is retained. The image contains a generated benchmark key shared
by the three guest disks for the two encrypted modes. It is a test key, not a
secret credential. The runner needs root access to QEMU KVM, the realm console
sockets, and `/dev/shm`; use `sudo` if the `user` account lacks that access.

## Patches

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
only the still-required patches through the guarded patch mechanism above.
