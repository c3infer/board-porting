#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_KEY_FILE="$SCRIPT_DIR/benchmark.key"

DEV_TX="${MB_RG_DEV_TX:-/sys/bus/pci/devices/0000:00:03.0/resource2}"
DEV_RX="${MB_RG_DEV_RX:-/sys/bus/pci/devices/0000:00:03.0/resource2}"

MAX_PAYLOAD=262112

usage() {
  echo "Usage: $0 [--enc|--no-enc] [--iters N] [--size-bytes N] [--key-file <path>]" >&2
}

now_ns() {
  date +%s%N
}

CRYPTO_MODE="${USECASE_CRYPTO:-0}"
KEY_FILE=""
ITERS=10
SIZE_BYTES=131072

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enc) CRYPTO_MODE=1; shift ;;
    --no-enc|--plain) CRYPTO_MODE=0; shift ;;
    --iters)
      [ $# -lt 2 ] && { usage; exit 2; }
      ITERS="$2"
      shift 2
      ;;
    --size-bytes)
      [ $# -lt 2 ] && { usage; exit 2; }
      SIZE_BYTES="$2"
      shift 2
      ;;
    --key-file)
      [ $# -lt 2 ] && { usage; exit 2; }
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "MB-RG: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ITERS" in
  ''|*[!0-9]*|0)
  echo "MB-RG: --iters must be a positive integer" >&2
  exit 2
  ;;
esac

case "$SIZE_BYTES" in
  ''|*[!0-9]*|0)
  echo "MB-RG: --size-bytes must be a positive integer" >&2
  exit 2
  ;;
esac

if (( SIZE_BYTES > MAX_PAYLOAD )); then
  echo "MB-RG: --size-bytes exceeds max payload ($SIZE_BYTES > $MAX_PAYLOAD)" >&2
  exit 2
fi

export USECASE_CRYPTO="$CRYPTO_MODE"

if [ "$USECASE_CRYPTO" = "1" ]; then
  if [ -z "${USECASE_SHARED_KEY:-}" ]; then
    if [ -n "$KEY_FILE" ]; then
      [ -r "$KEY_FILE" ] || { echo "MB-RG: key file not readable: $KEY_FILE" >&2; exit 1; }
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$KEY_FILE" | tr -d '\r\n')"
    elif [ -r "$DEFAULT_KEY_FILE" ]; then
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$DEFAULT_KEY_FILE" | tr -d '\r\n')"
    fi
  fi
  [ -n "${USECASE_SHARED_KEY:-}" ] || {
    echo "MB-RG: --enc set but no key. Set USECASE_SHARED_KEY or provide --key-file." >&2
    exit 1
  }
fi

TMP_DIR="$(mktemp -d /tmp/microbenchmark_rg.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PAYLOAD_FILE="$TMP_DIR/payload.bin"
REPLY_FILE="$TMP_DIR/reply.bin"
head -c "$SIZE_BYTES" /dev/zero > "$PAYLOAD_FILE"

MODE_NAME="no-enc"
if [ "$USECASE_CRYPTO" = "1" ]; then
  MODE_NAME="enc"
fi
echo "MB-RG: mode=$MODE_NAME iters=$ITERS size_bytes=$SIZE_BYTES"
echo "MB-RG: expected counterpart: microbenchmark_app_re.sh with same --iters"

total_ns=0
for ((i=1; i<=ITERS; i++)); do
  t0="$(now_ns)"
  "$SCRIPT_DIR/stream_send.sh" "$DEV_TX" "$PAYLOAD_FILE" 262144 "MB-RG-TX#$i"
  "$SCRIPT_DIR/stream_recv.sh" "$DEV_RX" "$REPLY_FILE" 1 "MB-RG-RX#$i"
  t1="$(now_ns)"

  dt_ns=$((t1 - t0))
  total_ns=$((total_ns + dt_ns))

  echo "MB-RG: iter=$i roundtrip_ns=$dt_ns roundtrip_us=$((dt_ns / 1000)) roundtrip_ms=$((dt_ns / 1000000))"
done

avg_ns=$((total_ns / ITERS))
avg_us=$((avg_ns / 1000))
avg_ms=$((avg_ns / 1000000))
bytes_total=$((SIZE_BYTES * ITERS * 2))
throughput_mib_x100=$(( (bytes_total * 100 * 1000000000) / total_ns / 1024 / 1024 ))

echo "MB-RG: summary total_ns=$total_ns avg_ns=$avg_ns avg_us=$avg_us avg_ms=$avg_ms bytes_total=$bytes_total throughput_mib_s_x100=$throughput_mib_x100"
