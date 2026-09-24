#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_KEY_FILE="$SCRIPT_DIR/benchmark.key"

DEV_IN="${MB_RE_DEV_IN:-/sys/bus/pci/devices/0000:00:03.0/resource2}"
DEV_OUT="${MB_RE_DEV_OUT:-/sys/bus/pci/devices/0000:00:03.0/resource2}"

usage() {
  echo "Usage: $0 [--enc|--no-enc] [--iters N] [--key-file <path>]" >&2
}

now_ns() {
  date +%s%N
}

CRYPTO_MODE="${USECASE_CRYPTO:-0}"
KEY_FILE=""
ITERS=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enc) CRYPTO_MODE=1; shift ;;
    --no-enc|--plain) CRYPTO_MODE=0; shift ;;
    --iters)
      [ $# -lt 2 ] && { usage; exit 2; }
      ITERS="$2"
      shift 2
      ;;
    --key-file)
      [ $# -lt 2 ] && { usage; exit 2; }
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "MB-RE: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ITERS" in
  ''|*[!0-9]*|0)
  echo "MB-RE: --iters must be a positive integer" >&2
  exit 2
  ;;
esac

export USECASE_CRYPTO="$CRYPTO_MODE"

if [ "$USECASE_CRYPTO" = "1" ]; then
  if [ -z "${USECASE_SHARED_KEY:-}" ]; then
    if [ -n "$KEY_FILE" ]; then
      [ -r "$KEY_FILE" ] || { echo "MB-RE: key file not readable: $KEY_FILE" >&2; exit 1; }
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$KEY_FILE" | tr -d '\r\n')"
    elif [ -r "$DEFAULT_KEY_FILE" ]; then
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$DEFAULT_KEY_FILE" | tr -d '\r\n')"
    fi
  fi
  [ -n "${USECASE_SHARED_KEY:-}" ] || {
    echo "MB-RE: --enc set but no key. Set USECASE_SHARED_KEY or provide --key-file." >&2
    exit 1
  }
fi

TMP_DIR="$(mktemp -d /tmp/microbenchmark_re.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

IN_FILE="$TMP_DIR/in.bin"
OUT_FILE="$TMP_DIR/out.bin"

MODE_NAME="no-enc"
if [ "$USECASE_CRYPTO" = "1" ]; then
  MODE_NAME="enc"
fi
echo "MB-RE: mode=$MODE_NAME iters=$ITERS"

total_ns=0
for ((i=1; i<=ITERS; i++)); do
  t0="$(now_ns)"
  "$SCRIPT_DIR/stream_recv.sh" "$DEV_IN" "$IN_FILE" 1 "MB-RE-RX#$i"
  cp -f "$IN_FILE" "$OUT_FILE"
  "$SCRIPT_DIR/stream_send.sh" "$DEV_OUT" "$OUT_FILE" 262144 "MB-RE-TX#$i"
  t1="$(now_ns)"

  dt_ns=$((t1 - t0))
  total_ns=$((total_ns + dt_ns))
  echo "MB-RE: iter=$i service_ns=$dt_ns service_us=$((dt_ns / 1000)) service_ms=$((dt_ns / 1000000))"
done

avg_ns=$((total_ns / ITERS))
echo "MB-RE: summary total_ns=$total_ns avg_ns=$avg_ns avg_us=$((avg_ns / 1000)) avg_ms=$((avg_ns / 1000000))"
