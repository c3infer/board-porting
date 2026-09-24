#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <device_path> <output_file> [poll_sleep_sec=1] [tag=RX]" >&2
  exit 2
fi

DEV="$1"
OUT_FILE="$2"
POLL_SLEEP="${3:-1}"
TAG="${4:-RX}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_UTILS="$SCRIPT_DIR/crypto_utils.sh"

now_ns() {
  date +%s%N
}

if [[ -f "$COMMON_UTILS" ]]; then
  # shellcheck source=/dev/null
  source "$COMMON_UTILS"
fi

TMP_DIR="$(mktemp -d /tmp/stream_recv.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

: > "$OUT_FILE"

if ! [[ "$POLL_SLEEP" =~ ^[0-9]+$ ]]; then
  POLL_SLEEP=1
fi

if (( POLL_SLEEP > 60 )); then
  # Backward compatibility with old callers passing chunk size here.
  POLL_SLEEP=1
fi

if command -v crypto_enabled >/dev/null 2>&1 && crypto_enabled; then
  echo "$TAG: crypto=on, waiting with rw_ivshmem -C"
  dec_fail_count=0
  dec_fail_total_ns=0
  while true; do
    ENC_TMP="$TMP_DIR/recv_payload.enc"
    "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -C "$ENC_TMP"
    dec_t0_ns="$(now_ns)"
    if crypto_decrypt_file "$ENC_TMP" "$OUT_FILE"; then
      dec_t1_ns="$(now_ns)"
      dec_dt_ns=$((dec_t1_ns - dec_t0_ns))
      RECV="$(wc -c < "$OUT_FILE")"
      echo "$TAG: crypto=on decrypted payload"
      echo "$TAG: crypto_decrypt_ns=$dec_dt_ns crypto_decrypt_us=$((dec_dt_ns / 1000)) crypto_decrypt_ms=$((dec_dt_ns / 1000000)) decrypt_fail_count=$dec_fail_count decrypt_fail_total_ns=$dec_fail_total_ns"
      echo "$TAG: receive complete ($RECV bytes) -> $OUT_FILE"
      exit 0
    fi
    dec_t1_ns="$(now_ns)"
    dec_fail_count=$((dec_fail_count + 1))
    dec_fail_total_ns=$((dec_fail_total_ns + dec_t1_ns - dec_t0_ns))
    : > "$OUT_FILE"
    echo "$TAG: decrypt/auth failed, waiting for next payload..."
    sleep "$POLL_SLEEP"
  done
fi

echo "$TAG: waiting for complete payload on $DEV using rw_ivshmem -R polling"

while true; do
  HDR_FILE="$TMP_DIR/hdr.bin"
  "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -R 32 | head -c 32 > "$HDR_FILE"

  MAGIC="$(dd if="$HDR_FILE" bs=1 skip=8 count=8 2>/dev/null | tr -d '\000')"
  READY_RAW="$(od -An -t u4 -j24 -N4 "$HDR_FILE" 2>/dev/null | tr -d '[:space:]')"
  LEN_RAW="$(od -An -t u8 -j16 -N8 "$HDR_FILE" 2>/dev/null | tr -d '[:space:]')"

  READY="${READY_RAW:-0}"
  LENGTH="${LEN_RAW:-0}"
  STATUS="ready=$READY len=$LENGTH magic=${MAGIC:-<none>}"

  if [[ "$MAGIC" == "IVSHFILE" && "$READY" == "1" && "$LENGTH" != "0" ]]; then
    # Confirm header is stable across two polls before dumping payload.
    sleep 0.1
    HDR_FILE2="$TMP_DIR/hdr2.bin"
    "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -R 32 | head -c 32 > "$HDR_FILE2"
    MAGIC2="$(dd if="$HDR_FILE2" bs=1 skip=8 count=8 2>/dev/null | tr -d '\000')"
    READY2_RAW="$(od -An -t u4 -j24 -N4 "$HDR_FILE2" 2>/dev/null | tr -d '[:space:]')"
    LEN2_RAW="$(od -An -t u8 -j16 -N8 "$HDR_FILE2" 2>/dev/null | tr -d '[:space:]')"
    READY2="${READY2_RAW:-0}"
    LENGTH2="${LEN2_RAW:-0}"
    if [[ "$MAGIC2" != "IVSHFILE" || "$READY2" != "$READY" || "$LENGTH2" != "$LENGTH" ]]; then
      echo "$TAG: header not stable yet (first: $STATUS second: ready=$READY2 len=$LENGTH2 magic=${MAGIC2:-<none>}), retrying"
      sleep "$POLL_SLEEP"
      continue
    fi

    echo "$TAG: payload ready and stable (len=$LENGTH), dumping..."
    if command -v crypto_enabled >/dev/null 2>&1 && crypto_enabled; then
      ENC_TMP="$TMP_DIR/recv_payload.enc"
      "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -D "$ENC_TMP"
      if crypto_decrypt_file "$ENC_TMP" "$OUT_FILE"; then
        echo "$TAG: crypto=on decrypted payload"
      else
        : > "$OUT_FILE"
        echo "$TAG: decrypt failed (stale/in-flight payload?), continuing to poll..."
        sleep "$POLL_SLEEP"
        continue
      fi
    else
      "$SCRIPT_DIR/rw_ivshmem" -f "$DEV" -D "$OUT_FILE"
      echo "$TAG: crypto=off"
    fi
    break
  fi

  echo "$TAG: waiting... $STATUS"
  sleep "$POLL_SLEEP"
done

RECV="$(wc -c < "$OUT_FILE")"
echo "$TAG: receive complete ($RECV bytes) -> $OUT_FILE"
