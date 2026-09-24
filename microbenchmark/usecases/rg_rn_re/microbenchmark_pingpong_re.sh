#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_KEY_FILE="$SCRIPT_DIR/../common/usecase_shared.key"

DEV_IN="${MB_RE_DEV_IN:-/sys/bus/pci/devices/0000:00:03.0/resource2}"
DEV_OUT="${MB_RE_DEV_OUT:-/sys/bus/pci/devices/0000:00:03.0/resource2}"

MAX_PAYLOAD=262112

usage() {
  cat >&2 <<EOF
Usage: $0 [--enc|--no-enc] [--iters N] [--sizes "1024,4096,..."] [--key-file <path>]
EOF
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
    dd if="$out_file" of="${out_file}.trunc" bs=1 count="$total_size" status=none
    mv -f "${out_file}.trunc" "$out_file"
  fi
}

CRYPTO_MODE="${USECASE_CRYPTO:-0}"
KEY_FILE=""
ITERS=20
SIZES_CSV="1024,4096,16384,65536,131072,262112,1048576,10485760"

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
    --key-file)
      [ $# -lt 2 ] && { usage; exit 2; }
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "PINGPONG-RE: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ITERS" in
  ''|*[!0-9]*|0)
    echo "PINGPONG-RE: --iters must be a positive integer" >&2
    exit 2
    ;;
esac

export USECASE_CRYPTO="$CRYPTO_MODE"
if [ "$USECASE_CRYPTO" = "1" ]; then
  if [ -z "${USECASE_SHARED_KEY:-}" ]; then
    if [ -n "$KEY_FILE" ]; then
      [ -r "$KEY_FILE" ] || { echo "PINGPONG-RE: key file not readable: $KEY_FILE" >&2; exit 1; }
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$KEY_FILE" | tr -d '\r\n')"
    elif [ -r "$DEFAULT_KEY_FILE" ]; then
      export USECASE_SHARED_KEY
      USECASE_SHARED_KEY="$(head -n 1 "$DEFAULT_KEY_FILE" | tr -d '\r\n')"
    fi
  fi
  [ -n "${USECASE_SHARED_KEY:-}" ] || {
    echo "PINGPONG-RE: --enc set but no key. Set USECASE_SHARED_KEY or provide --key-file." >&2
    exit 1
  }
fi

MODE_NAME="no-enc"
[ "$USECASE_CRYPTO" = "1" ] && MODE_NAME="enc"
echo "PINGPONG-RE: mode=$MODE_NAME iters=$ITERS sizes=$SIZES_CSV"

TMP_DIR="$(mktemp -d /tmp/pingpong_re.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
IN_FILE="$TMP_DIR/in.bin"
OUT_FILE="$TMP_DIR/out.bin"

IFS=',' read -r -a SIZES <<< "$SIZES_CSV"
for raw in "${SIZES[@]}"; do
  size="$(echo "$raw" | tr -d '[:space:]')"
  case "$size" in
    ''|*[!0-9]*|0)
      echo "PINGPONG-RE: skip invalid size '$raw'"
      continue
      ;;
  esac

  chunks=$(( (size + MAX_PAYLOAD - 1) / MAX_PAYLOAD ))

  for ((i=1; i<=ITERS; i++)); do
    remaining="$size"
    for ((c=1; c<=chunks; c++)); do
      expected="$MAX_PAYLOAD"
      if [ "$remaining" -lt "$MAX_PAYLOAD" ]; then
        expected="$remaining"
      fi

      req_header="RGREQ|size=${size}|iter=${i}|chunk=${c}|chunks=${chunks}|"
      rsp_header="RERSP|size=${size}|iter=${i}|chunk=${c}|chunks=${chunks}|"

      got_expected=0
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        "$SCRIPT_DIR/stream_recv.sh" "$DEV_IN" "$IN_FILE" 0 "PP-RE-RX[size=${size}][${i}/${ITERS}][chunk=${c}/${chunks}][try=${attempt}]"
        recv_size="$(wc -c < "$IN_FILE")"

        if dd if="$IN_FILE" bs=1 count="${#req_header}" status=none 2>/dev/null | \
           cmp -s - <(printf '%s' "$req_header"); then
          if [ "$recv_size" -ne "$expected" ]; then
            echo "PINGPONG-RE: warning size mismatch expected=$expected got=$recv_size (size=$size iter=$i chunk=$c)"
          fi
          got_expected=1
          break
        fi

        echo "PINGPONG-RE: ignoring non-request frame (size=$size iter=$i chunk=$c try=$attempt)"
      done

      if [ "$got_expected" -ne 1 ]; then
        echo "PINGPONG-RE: failed to receive expected request frame (size=$size iter=$i chunk=$c)" >&2
        exit 1
      fi

      make_frame "$OUT_FILE" "$recv_size" "$rsp_header"
      "$SCRIPT_DIR/stream_send.sh" "$DEV_OUT" "$OUT_FILE" 262144 "PP-RE-TX[size=${size}][${i}/${ITERS}][chunk=${c}/${chunks}]"

      remaining=$((remaining - expected))
    done
  done

  echo "PINGPONG-RE: completed size=$size chunks=$chunks iters=$ITERS"
done

echo "PINGPONG-RE: done"
