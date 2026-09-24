#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <device_path> <input_file> [ignored_chunk_bytes] [tag=TX]" >&2
  exit 2
fi

DEV="$1"
IN_FILE="$2"
CHUNK_BYTES="${3:-262144}"
TAG="${4:-TX}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_UTILS="$SCRIPT_DIR/crypto_utils.sh"

now_ns() {
  date +%s%N
}

if [[ -f "$COMMON_UTILS" ]]; then
  # shellcheck source=/dev/null
  source "$COMMON_UTILS"
fi

if [[ ! -r "$IN_FILE" ]]; then
  echo "$TAG: input file not readable: $IN_FILE" >&2
  exit 1
fi

FILE_SIZE="$(wc -c < "$IN_FILE")"
MAX_PAYLOAD=240000
if (( FILE_SIZE > MAX_PAYLOAD )); then
  echo "$TAG: input too large for one-slot payload ($FILE_SIZE > $MAX_PAYLOAD)" >&2
  exit 1
fi

if [[ ! -x "$SCRIPT_DIR/rw_ivshmem" ]]; then
  echo "$TAG: missing $SCRIPT_DIR/rw_ivshmem" >&2
  exit 1
fi

PAYLOAD_FILE="$IN_FILE"
TMP_ENC=""
cleanup() {
  if [[ -n "${TMP_ENC:-}" && -f "$TMP_ENC" ]]; then
    rm -f "$TMP_ENC"
  fi
}
trap cleanup EXIT

if command -v crypto_enabled >/dev/null 2>&1 && crypto_enabled; then
  TMP_ENC="$(mktemp /tmp/stream_send_enc.XXXXXX)"
  enc_t0_ns="$(now_ns)"
  crypto_encrypt_file "$IN_FILE" "$TMP_ENC"
  enc_t1_ns="$(now_ns)"
  PAYLOAD_FILE="$TMP_ENC"
  ENC_SIZE="$(wc -c < "$PAYLOAD_FILE")"
  enc_dt_ns=$((enc_t1_ns - enc_t0_ns))
  echo "$TAG: crypto=on encrypted payload size $ENC_SIZE bytes"
  echo "$TAG: crypto_encrypt_ns=$enc_dt_ns crypto_encrypt_us=$((enc_dt_ns / 1000)) crypto_encrypt_ms=$((enc_dt_ns / 1000000))"
  echo "$TAG: sending '$PAYLOAD_FILE' on $DEV using rw_ivshmem -P (enc mode)"
  "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -P "$PAYLOAD_FILE"
  echo "$TAG: send complete ($FILE_SIZE bytes)"
  exit 0
else
  echo "$TAG: crypto=off"
fi

SEND_REPEAT="${STREAM_SEND_REPEAT:-}"
if [[ -z "$SEND_REPEAT" ]]; then
  SEND_REPEAT=1
fi
if ! [[ "$SEND_REPEAT" =~ ^[1-9][0-9]*$ ]]; then
  SEND_REPEAT=1
fi

for ((i=1; i<=SEND_REPEAT; i++)); do
  echo "$TAG: sending '$PAYLOAD_FILE' on $DEV using rw_ivshmem -F (attempt $i/$SEND_REPEAT, arg3=$CHUNK_BYTES ignored)"
  "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -z 262144 -F "$PAYLOAD_FILE"
  # Small spacing helps receiver-side poll loops catch fresh header transitions.
  if (( i < SEND_REPEAT )); then
    sleep 0.1
  fi
done

echo "$TAG: send complete ($FILE_SIZE bytes)"
