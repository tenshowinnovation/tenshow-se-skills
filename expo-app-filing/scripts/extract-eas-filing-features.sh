#!/usr/bin/env bash
set -euo pipefail

TMP_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  extract-eas-filing-features.sh [expo-app-dir]

Reads EAS credentials downloaded into an Expo app directory and prints
China APP filing fields:
  - iOS Bundle ID
  - iOS SHA1 fingerprint
  - iOS public key modulus
  - Android package name
  - Android MD5 fingerprint
  - Android public key modulus

The script never prints passwords, private keys, or credentials.json content.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

resolve_path() {
  local base="$1"
  local path="$2"
  if [[ -z "$path" || "$path" == "null" ]]; then
    return 1
  fi
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$base" "$path"
  fi
}

json_get() {
  local file="$1"
  local expr="$2"
  jq -r "$expr // empty" "$file"
}

read_expo_config() {
  local app_dir="$1"
  local out="$2"

  if command -v npx >/dev/null 2>&1; then
    if (cd "$app_dir" && npx --yes expo config --json >"$out" 2>/dev/null); then
      return 0
    fi
  fi

  if [[ -f "$app_dir/app.json" ]]; then
    cp "$app_dir/app.json" "$out"
    return 0
  fi

  printf '{}\n' >"$out"
}

fingerprint() {
  local cert="$1"
  local algo="$2"
  openssl x509 -in "$cert" -noout -fingerprint "$algo" | sed 's/.*=//;s/://g'
}

public_key_modulus() {
  local cert="$1"
  openssl x509 -in "$cert" -noout -modulus | sed 's/Modulus=//'
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  need_cmd jq
  need_cmd openssl

  local app_dir="${1:-.}"
  app_dir="$(cd "$app_dir" && pwd)"
  local credentials_json="$app_dir/credentials.json"
  [[ -f "$credentials_json" ]] || die "credentials.json not found in $app_dir. Download it from eas credentials first."

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  local expo_config="$TMP_DIR/expo-config.json"
  read_expo_config "$app_dir" "$expo_config"

  local app_name owner slug bundle_id android_package
  app_name="$(json_get "$expo_config" '.expo.name // .name')"
  owner="$(json_get "$expo_config" '.expo.owner // .owner')"
  slug="$(json_get "$expo_config" '.expo.slug // .slug')"
  bundle_id="$(json_get "$expo_config" '.expo.ios.bundleIdentifier // .ios.bundleIdentifier')"
  android_package="$(json_get "$expo_config" '.expo.android.package // .android.package')"

  printf 'APP_NAME=%s\n' "${app_name:-}"
  printf 'EXPO_OWNER=%s\n' "${owner:-}"
  printf 'EXPO_SLUG=%s\n' "${slug:-}"
  printf 'IOS_BUNDLE_ID=%s\n' "${bundle_id:-}"
  printf 'ANDROID_PACKAGE=%s\n' "${android_package:-}"

  local ios_p12 ios_pass ios_cert ios_pass_file
  ios_p12="$(resolve_path "$app_dir" "$(json_get "$credentials_json" '.ios.distributionCertificate.path')" || true)"
  ios_pass="$(json_get "$credentials_json" '.ios.distributionCertificate.password')"

  if [[ -n "${ios_p12:-}" && -n "$ios_pass" && -f "$ios_p12" ]]; then
    ios_cert="$TMP_DIR/ios-cert.pem"
    ios_pass_file="$TMP_DIR/ios-pass"
    chmod 700 "$TMP_DIR"
    printf '%s' "$ios_pass" >"$ios_pass_file"
    chmod 600 "$ios_pass_file"
    openssl pkcs12 -in "$ios_p12" -clcerts -nokeys -out "$ios_cert" -passin "file:$ios_pass_file" >/dev/null 2>&1
    printf 'IOS_SHA1=%s\n' "$(fingerprint "$ios_cert" -sha1)"
    printf 'IOS_PUBLIC_KEY=%s\n' "$(public_key_modulus "$ios_cert")"
  else
    printf 'IOS_SHA1=\n'
    printf 'IOS_PUBLIC_KEY=\n'
    printf 'WARN_IOS=No EAS iOS distribution certificate found in credentials.json\n' >&2
  fi

  local android_keystore android_storepass android_alias android_cert
  android_keystore="$(resolve_path "$app_dir" "$(json_get "$credentials_json" '.android.keystore.keystorePath')" || true)"
  android_storepass="$(json_get "$credentials_json" '.android.keystore.keystorePassword')"
  android_alias="$(json_get "$credentials_json" '.android.keystore.keyAlias')"

  if [[ -n "${android_keystore:-}" && -n "$android_storepass" && -n "$android_alias" && -f "$android_keystore" ]]; then
    need_cmd keytool
    android_cert="$TMP_DIR/android-cert.pem"
    APP_FILING_KEYSTORE_PASSWORD="$android_storepass" \
      keytool -exportcert -rfc \
        -keystore "$android_keystore" \
        -alias "$android_alias" \
        -storepass:env APP_FILING_KEYSTORE_PASSWORD \
        -file "$android_cert" >/dev/null 2>&1
    printf 'ANDROID_MD5=%s\n' "$(fingerprint "$android_cert" -md5)"
    printf 'ANDROID_PUBLIC_KEY=%s\n' "$(public_key_modulus "$android_cert")"
  else
    printf 'ANDROID_MD5=\n'
    printf 'ANDROID_PUBLIC_KEY=\n'
    printf 'WARN_ANDROID=No EAS Android keystore found in credentials.json\n' >&2
  fi
}

main "$@"
