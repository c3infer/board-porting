#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$SCRIPT_DIR/configs/benchmarking_rg.json"
PREF_SHM1="$SCRIPT_DIR/configs/prefault_shm1.json"
PREF_SHM2="$SCRIPT_DIR/configs/prefault_shm2.json"

# shm1 on 00:03.0/resource2, shm2 on 00:04.0/resource2
DEV_TX="/sys/bus/pci/devices/0000:00:03.0/resource2"
DEV_RX="/sys/bus/pci/devices/0000:00:04.0/resource2"

cd "$SCRIPT_DIR"

usage() {
  echo "Usage: $0 [--enc|--no-enc]" >&2
}

now_ns() {
  date +%s%N
}

ns_to_us() {
  local ns="$1"
  echo $((ns / 1000))
}

ns_to_ms() {
  local ns="$1"
  echo $((ns / 1000000))
}

CRYPTO_MODE="${USECASE_CRYPTO:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enc) CRYPTO_MODE=1; shift ;;
    --no-enc|--plain) CRYPTO_MODE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "RG-MICROBENCH: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done
export USECASE_CRYPTO="$CRYPTO_MODE"

if [[ "$USECASE_CRYPTO" == "1" ]]; then
  MODE_NAME="enc"
else
  MODE_NAME="no-enc"
fi

echo "RG-MICROBENCH: mode=$MODE_NAME"

fault_t0_ns="$(now_ns)"
"$SCRIPT_DIR/rw_ivshmem" -f "$DEV_TX" --prefault "$PREF_SHM1"
"$SCRIPT_DIR/rw_ivshmem" -f "$DEV_RX" --prefault "$PREF_SHM2"
fault_t1_ns="$(now_ns)"

cfg_t0_ns="$(now_ns)"
if [[ "$USECASE_CRYPTO" == "1" ]]; then
  echo "RG-MICROBENCH: mode=enc, skipping config upload"
else
  cat "$CFG" > /dev/rsi_policy_json
fi
cfg_t1_ns="$(now_ns)"

fault_delta_ns=$((fault_t1_ns - fault_t0_ns))
cfg_delta_ns=$((cfg_t1_ns - cfg_t0_ns))

echo "RG-MICROBENCH: faulting_ns=$fault_delta_ns faulting_us=$(ns_to_us "$fault_delta_ns") faulting_ms=$(ns_to_ms "$fault_delta_ns")"
echo "RG-MICROBENCH: config_upload_ns=$cfg_delta_ns config_upload_us=$(ns_to_us "$cfg_delta_ns") config_upload_ms=$(ns_to_ms "$cfg_delta_ns")"
echo "RG microbenchmark setup complete"
