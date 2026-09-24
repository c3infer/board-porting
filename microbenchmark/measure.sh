#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
now_ns() { date +%s%N; }

case "${1:-}" in
  ready)
    printf 'MB_READY\n'
    ;;
  prefault)
    index=${2:?device index required}
    case "$index" in
      1) config="$HERE/configs/prefault_shm1.json" ;;
      2) config="$HERE/configs/prefault_shm2.json" ;;
      *) echo 'device index must be 1 or 2' >&2; exit 2 ;;
    esac
    "$HERE/rw_ivshmem" -f "/sys/bus/pci/devices/0000:00:0$((index + 2)).0/resource2" \
      --prefault "$config"
    printf 'MB_RESULT prefault=%s\n' "$index"
    ;;
  policy)
    policy=${2:?policy file required}
    test -r "$policy"
    t0=$(now_ns)
    cat "$policy" > /dev/rsi_policy_json
    t1=$(now_ns)
    printf 'MB_RESULT policy_upload_ns=%s\n' "$((t1 - t0))"
    ;;
  attest)
    base=/sys/kernel/config/tsm/report
    if ! mountpoint -q /sys/kernel/config; then
      mount -t configfs configfs /sys/kernel/config
    fi
    test -d "$base" || { echo 'TSM report interface unavailable' >&2; exit 1; }
    report="$base/microbenchmark-$$"
    mkdir "$report"
    nonce=$(mktemp)
    token=$(mktemp)
    trap 'rmdir "$report"; rm -f "$nonce" "$token"' EXIT
    head -c 32 /dev/urandom > "$nonce"
    t0=$(now_ns)
    cat "$nonce" > "$report/inblob"
    cat "$report/outblob" > "$token"
    t1=$(now_ns)
    bytes=$(wc -c < "$token")
    test "$bytes" -gt 0
    printf 'MB_RESULT attestation_ns=%s token_bytes=%s\n' "$((t1 - t0))" "$bytes"
    ;;
  communication)
    role=${2:?realm1 or realm2 required}
    mode=${3:?plain, cbc, or ctr required}
    iters=${4:?iterations required}
    sizes=${5:-65536,262144,524288,1048576,10485760}
    case "$mode" in
      plain) export USECASE_CRYPTO=0 USECASE_CRYPTO_FAST=0; flag=--no-enc ;;
      cbc) export USECASE_CRYPTO=1 USECASE_CRYPTO_FAST=0; flag=--enc ;;
      ctr) export USECASE_CRYPTO=1 USECASE_CRYPTO_FAST=1; flag=--enc ;;
      *) echo "Unknown communication mode: $mode" >&2; exit 2 ;;
    esac
    if [[ "$role" == realm1 ]]; then
      csv=$(mktemp)
      trap 'rm -f "$csv"' EXIT
      "$HERE/microbenchmark_pingpong_rg.sh" "$flag" --iters "$iters" \
        --sizes "$sizes" --csv-out "$csv"
      printf 'MB_CSV_BEGIN mode=%s\n' "$mode"
      cat "$csv"
      printf 'MB_CSV_END\n'
    elif [[ "$role" == realm2 ]]; then
      "$HERE/microbenchmark_pingpong_re.sh" "$flag" --iters "$iters" \
        --sizes "$sizes"
    else
      echo "Unknown communication role: $role" >&2; exit 2
    fi
    ;;
  *)
    echo 'Usage: measure.sh {ready|prefault INDEX|policy FILE|attest|communication ROLE MODE ITERS [SIZES]}' >&2
    exit 2
    ;;
esac
