#!/usr/bin/env bash
set -euo pipefail

crypto_enabled() {
  case "${USECASE_CRYPTO:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

crypto_key() {
  printf '%s' "${USECASE_SHARED_KEY:-caec-shared-demo-key-change-me}"
}

crypto_fast_enabled() {
  case "${USECASE_CRYPTO_FAST:-${USECASE_CRYPTO_MODE:-0}}" in
    1|true|TRUE|yes|YES|on|ON|fast|FAST) return 0 ;;
    *) return 1 ;;
  esac
}

crypto_key_hex() {
  printf '%s' "$(crypto_key)" | openssl dgst -sha256 | awk '{print $2}'
}

crypto_require_tools() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "crypto: openssl not found, but USECASE_CRYPTO is enabled" >&2
    exit 1
  fi
}

crypto_encrypt_file() {
  local in_file="$1"
  local out_file="$2"
  crypto_require_tools
  if crypto_fast_enabled; then
    local tmp_enc
    local tmp_auth
    local key_hex
    local iv_hex
    local hmac_hex

    tmp_enc="$(mktemp /tmp/crypto_fast_enc.XXXXXX)"
    tmp_auth="$(mktemp /tmp/crypto_fast_auth.XXXXXX)"
    key_hex="$(crypto_key_hex)"
    iv_hex="$(openssl rand -hex 16)"

    openssl enc -aes-256-ctr -nosalt \
      -K "$key_hex" -iv "$iv_hex" \
      -in "$in_file" -out "$tmp_enc"

    {
      printf '%s\n' "$iv_hex"
      cat "$tmp_enc"
    } > "$tmp_auth"
    hmac_hex="$(openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" "$tmp_auth" | awk '{print $2}')"

    {
      printf 'CAECENC2\n'
      printf '%s\n' "$iv_hex"
      printf '%s\n' "$hmac_hex"
      cat "$tmp_enc"
    } > "$out_file"

    rm -f "$tmp_enc" "$tmp_auth"
    return 0
  fi

  local tmp_enc
  local hmac_hex
  tmp_enc="$(mktemp /tmp/crypto_enc.XXXXXX)"

  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -md sha256 \
    -pass "pass:$(crypto_key)" \
    -in "$in_file" -out "$tmp_enc"

  hmac_hex="$(openssl dgst -sha256 -hmac "$(crypto_key)" "$tmp_enc" | awk '{print $2}')"
  {
    printf 'CAECENC1\n'
    printf '%s\n' "$hmac_hex"
    cat "$tmp_enc"
  } > "$out_file"
  rm -f "$tmp_enc"
}

crypto_decrypt_file() {
  local in_file="$1"
  local out_file="$2"
  crypto_require_tools
  local magic
  local hmac_hex=""
  local header_bytes
  local tmp_enc
  local calc_hmac
  local iv_hex=""
  local key_hex
  local tmp_auth

  IFS= read -r magic < "$in_file" || return 1
  tmp_enc="$(mktemp /tmp/crypto_dec.XXXXXX)"

  if [[ "$magic" == "CAECENC2" ]]; then
    IFS= read -r iv_hex < <(sed -n '2p' "$in_file") || { rm -f "$tmp_enc"; return 1; }
    IFS= read -r hmac_hex < <(sed -n '3p' "$in_file") || { rm -f "$tmp_enc"; return 1; }
    [[ "$iv_hex" =~ ^[0-9a-fA-F]{32}$ ]] || { rm -f "$tmp_enc"; return 1; }
    [[ "$hmac_hex" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$tmp_enc"; return 1; }

    header_bytes=$(( ${#magic} + 1 + ${#iv_hex} + 1 + ${#hmac_hex} + 1 ))
    dd if="$in_file" of="$tmp_enc" bs=1 skip="$header_bytes" status=none

    key_hex="$(crypto_key_hex)"
    tmp_auth="$(mktemp /tmp/crypto_fast_auth.XXXXXX)"
    {
      printf '%s\n' "$iv_hex"
      cat "$tmp_enc"
    } > "$tmp_auth"
    calc_hmac="$(openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" "$tmp_auth" | awk '{print $2}')"
    rm -f "$tmp_auth"
    if [[ "${calc_hmac,,}" != "${hmac_hex,,}" ]]; then
      rm -f "$tmp_enc"
      return 1
    fi

    openssl enc -d -aes-256-ctr -nosalt \
      -K "$key_hex" -iv "$iv_hex" \
      -in "$tmp_enc" -out "$out_file"
    rm -f "$tmp_enc"
    return 0
  fi

  if [[ "$magic" != "CAECENC1" ]]; then
    rm -f "$tmp_enc"
    return 1
  fi

  IFS= read -r hmac_hex < <(sed -n '2p' "$in_file") || { rm -f "$tmp_enc"; return 1; }
  [[ "$hmac_hex" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$tmp_enc"; return 1; }

  header_bytes=$(( ${#magic} + 1 + ${#hmac_hex} + 1 ))
  dd if="$in_file" of="$tmp_enc" bs=1 skip="$header_bytes" status=none
  calc_hmac="$(openssl dgst -sha256 -hmac "$(crypto_key)" "$tmp_enc" | awk '{print $2}')"
  if [[ "${calc_hmac,,}" != "${hmac_hex,,}" ]]; then
    rm -f "$tmp_enc"
    return 1
  fi

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 \
    -pass "pass:$(crypto_key)" \
    -in "$tmp_enc" -out "$out_file"
  rm -f "$tmp_enc"
}
