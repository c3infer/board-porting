#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_KEY_FILE="$SCRIPT_DIR/benchmark.key"

DEV_TX="${MB_RG_DEV_TX:-/sys/bus/pci/devices/0000:00:03.0/resource2}"
DEV_RX="${MB_RG_DEV_RX:-/sys/bus/pci/devices/0000:00:03.0/resource2}"

MAX_PAYLOAD=240000

usage() {
  cat >&2 <<EOF
Usage: $0 [--enc|--no-enc] [--iters N] [--sizes "1024,4096,..."] [--csv-out <path>] [--key-file <path>]
EOF
}

now_ns() {
  date +%s%N
}

make_frame() {
  local out_file="$1"
  local total_size="$2"
  local header="$3"
  local hdr_len
  hdr_len="$(printf '%s' "$header" | wc -c)"
  : > "$out_file"
  printf '%s' "$header" > "$out_file"
  if [ "$hdr_len" -lt "$total_size" ]; then
    head -c $((total_size - hdr_len)) /dev/zero >> "$out_file"
  else
    # Keep exact payload size.
    dd if="$out_file" of="${out_file}.trunc" bs=1 count="$total_size" status=none
    mv -f "${out_file}.trunc" "$out_file"
  fi
}

CRYPTO_MODE="${USECASE_CRYPTO:-0}"
KEY_FILE=""
ITERS=20
SIZES_CSV="65536,262144,524288,1048576,10485760"
CSV_OUT="$SCRIPT_DIR/pingpong_results_rg.csv"

while [ $# -gt 0 ]; do
  case "$1" in
    --enc) CRYPTO_MODE=1; shift ;;
    --no-enc|--plain) CRYPTO_MODE=0; shift ;;
    --iters)
      [ $# -lt 2 ] && { usage; exit 2; }
      ITERS="$2"
      shift 2
      ;;
    --sizes)
      [ $# -lt 2 ] && { usage; exit 2; }
      SIZES_CSV="$2"
      shift 2
      ;;
    --csv-out)
      [ $# -lt 2 ] && { usage; exit 2; }
      CSV_OUT="$2"
      shift 2
      ;;
    --key-file)
      [ $# -lt 2 ] && { usage; exit 2; }
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "PINGPONG-RG: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ITERS" in
  ''|*[!0-9]*|0)
    echo "PINGPONG-RG: --iters must be a positive integer" >&2
    exit 2
    ;;
esac

export USECASE_CRYPTO="$CRYPTO_MODE"
if [ "$USECASE_CRYPTO" = "1" ]; then
  if [ -z "${USECASE_SHARED_KEY:-}" ]; then
    if [ -n "$KEY_FILE" ]; then
      [ -r "$KEY_FILE" ] || { echo "PINGPONG-RG: key file not readable: $KEY_FILE" >&2; exit 1; }
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$KEY_FILE" | tr -d '\r\n')"
    elif [ -r "$DEFAULT_KEY_FILE" ]; then
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$DEFAULT_KEY_FILE" | tr -d '\r\n')"
    fi
  fi
  [ -n "${USECASE_SHARED_KEY:-}" ] || {
    echo "PINGPONG-RG: --enc set but no key. Set USECASE_SHARED_KEY or provide --key-file." >&2
    exit 1
  }
fi

MODE_NAME="no-enc"
[ "$USECASE_CRYPTO" = "1" ] && MODE_NAME="enc"

TMP_DIR="$(mktemp -d /tmp/pingpong_rg.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "PINGPONG-RG: mode=$MODE_NAME iters=$ITERS sizes=$SIZES_CSV"
echo "PINGPONG-RG: max single payload per chunk is $MAX_PAYLOAD bytes (chunk streaming enabled)"
echo "mode,size_bytes,iters,total_ns,avg_ns,avg_us,avg_ms,filtered_total_ns,filtered_avg_ns,retry_noise_ns,retry_miss_count" > "$CSV_OUT"

IFS=',' read -r -a SIZES <<< "$SIZES_CSV"
for raw in "${SIZES[@]}"; do
  size="$(echo "$raw" | tr -d '[:space:]')"
  case "$size" in
    ''|*[!0-9]*|0)
      echo "PINGPONG-RG: skip invalid size '$raw'"
      continue
      ;;
  esac

  reply_chunk="$TMP_DIR/reply_chunk.bin"

  chunks=$(( (size + MAX_PAYLOAD - 1) / MAX_PAYLOAD ))

  # Prepare deterministic request frames before starting the timer.
  for ((i=1; i<=ITERS; i++)); do
    remaining="$size"
    for ((c=1; c<=chunks; c++)); do
      csize="$MAX_PAYLOAD"
      if [ "$remaining" -lt "$MAX_PAYLOAD" ]; then csize="$remaining"; fi
      req_header="RGREQ|size=${size}|iter=${i}|chunk=${c}|chunks=${chunks}|"
      make_frame "$TMP_DIR/payload_${size}_iter${i}_chunk${c}.bin" "$csize" "$req_header"
      remaining=$((remaining - csize))
    done
  done

  total_ns=0
  retry_noise_ns=0
  retry_miss_count=0
  for ((i=1; i<=ITERS; i++)); do
    t0="$(now_ns)"

    remaining="$size"
    for ((c=1; c<=chunks; c++)); do
      csize="$MAX_PAYLOAD"
      if [ "$remaining" -lt "$MAX_PAYLOAD" ]; then
        csize="$remaining"
      fi

      payload_chunk="$TMP_DIR/payload_${size}_iter${i}_chunk${c}.bin"
      req_header="RGREQ|size=${size}|iter=${i}|chunk=${c}|chunks=${chunks}|"
      rsp_header="RERSP|size=${size}|iter=${i}|chunk=${c}|chunks=${chunks}|"

      "$SCRIPT_DIR/stream_send.sh" "$DEV_TX" "$payload_chunk" 262144 "PP-RG-TX[size=${size}][${i}/${ITERS}][chunk=${c}/${chunks}]"

      got_expected=0
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        rx_try_t0_ns="$(now_ns)"
        "$SCRIPT_DIR/stream_recv.sh" "$DEV_RX" "$reply_chunk" 0 "PP-RG-RX[size=${size}][${i}/${ITERS}][chunk=${c}/${chunks}][try=${attempt}]"
        rx_try_t1_ns="$(now_ns)"
        rx_try_dt_ns=$((rx_try_t1_ns - rx_try_t0_ns))
        reply_size="$(wc -c < "$reply_chunk")"

        if dd if="$reply_chunk" bs=1 count="${#rsp_header}" status=none 2>/dev/null | \
           cmp -s - <(printf '%s' "$rsp_header"); then
          if [ "$reply_size" -ne "$csize" ]; then
            echo "PINGPONG-RG: warning reply size mismatch expected=$csize got=$reply_size (size=$size iter=$i chunk=$c)"
          fi
          got_expected=1
          break
        fi

        retry_noise_ns=$((retry_noise_ns + rx_try_dt_ns))
        retry_miss_count=$((retry_miss_count + 1))
        echo "PINGPONG-RG: ignoring non-reply frame (size=$size iter=$i chunk=$c try=$attempt)"
      done

      if [ "$got_expected" -ne 1 ]; then
        echo "PINGPONG-RG: failed to receive expected reply frame (size=$size iter=$i chunk=$c)" >&2
        exit 1
      fi

      remaining=$((remaining - csize))
    done

    t1="$(now_ns)"
    dt_ns=$((t1 - t0))
    total_ns=$((total_ns + dt_ns))
  done

  avg_ns=$((total_ns / ITERS))
  avg_us=$((avg_ns / 1000))
  avg_ms=$((avg_ns / 1000000))
  filtered_total_ns=$((total_ns - retry_noise_ns))
  if [ "$filtered_total_ns" -lt 0 ]; then
    filtered_total_ns=0
  fi
  filtered_avg_ns=$((filtered_total_ns / ITERS))

  echo "PINGPONG-RG: size=$size chunks=$chunks iters=$ITERS total_ns=$total_ns avg_ns=$avg_ns avg_us=$avg_us avg_ms=$avg_ms filtered_total_ns=$filtered_total_ns filtered_avg_ns=$filtered_avg_ns retry_noise_ns=$retry_noise_ns retry_miss_count=$retry_miss_count"
  echo "$MODE_NAME,$size,$ITERS,$total_ns,$avg_ns,$avg_us,$avg_ms,$filtered_total_ns,$filtered_avg_ns,$retry_noise_ns,$retry_miss_count" >> "$CSV_OUT"
done

echo "PINGPONG-RG: results written to $CSV_OUT"
