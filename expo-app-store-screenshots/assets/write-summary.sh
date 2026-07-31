#!/usr/bin/env bash
# Write <DIR>/summary.md with capture provenance and screen inventory.
#
# Legacy usage:
#   bash write-summary.sh ios <UDID> <DIR> <LOCALE> [SCREEN_ROW]...
#
# Extended usage:
#   bash write-summary.sh ios <UDID> <DIR> <LOCALE> \
#     [--orientation VALUE] [--app-id ID] [--app-version VERSION] \
#     [--app-build BUILD] [--plan-hash HASH] \
#     [--simulator-override yes|no] [--validation STATUS] \
#     -- [SCREEN_ROW]...

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: write-summary.sh <ios|android> <UDID|SERIAL|-> <DIR> <LOCALE>
       [--orientation VALUE]
       [--app-id ID]
       [--app-version VERSION]
       [--app-build BUILD]
       [--plan-hash HASH]
       [--simulator-override yes|no]
       [--validation STATUS]
       [--] [SCREEN_ROW]...
EOF
}

if [[ $# -lt 4 ]]; then
  usage
  exit 2
fi

platform="$1"
target="$2"
dir="$3"
locale="$4"
shift 4

orientation=""
app_id=""
app_version=""
app_build=""
plan_hash=""
simulator_override="no"
validation="not-run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --orientation) orientation="${2:-}"; shift 2 ;;
    --app-id) app_id="${2:-}"; shift 2 ;;
    --app-version) app_version="${2:-}"; shift 2 ;;
    --app-build) app_build="${2:-}"; shift 2 ;;
    --plan-hash) plan_hash="${2:-}"; shift 2 ;;
    --simulator-override) simulator_override="${2:-}"; shift 2 ;;
    --validation) validation="${2:-}"; shift 2 ;;
    --) shift; break ;;
    --*) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done
screen_rows=("$@")
screen_row_count=$#

if [[ ! -d "$dir" ]]; then
  echo "error: not a directory: $dir" >&2
  exit 2
fi
case "$platform" in
  ios|android) ;;
  *) echo "error: platform must be ios or android" >&2; exit 2 ;;
esac
case "$simulator_override" in
  yes|no) ;;
  *) echo "error: --simulator-override must be yes or no" >&2; exit 2 ;;
esac

device_label="$(basename "$dir")"
captured="$(date '+%Y-%m-%d')"
png="$(find "$dir" -maxdepth 1 -name '*.png' -print -quit 2>/dev/null || true)"
if [[ -n "$png" ]] && command -v magick >/dev/null 2>&1; then
  resolution="$(magick identify -format '%wx%h' "$png")"
else
  resolution="(no PNG found)"
fi
if [[ -z "$orientation" && "$resolution" =~ ^([0-9]+)x([0-9]+)$ ]]; then
  if [[ "${BASH_REMATCH[1]}" -gt "${BASH_REMATCH[2]}" ]]; then
    orientation="landscape"
  else
    orientation="portrait"
  fi
fi
: "${orientation:=(unknown)}"

case "$platform" in
  ios)
    line=$(
      xcrun simctl list devices 2>/dev/null \
        | awk -v udid="$target" '
            /^-- / { runtime=$0; sub(/^-- /, "", runtime); sub(/ --$/, "", runtime) }
            $0 ~ udid { print runtime "|" $0; exit }
          '
    )
    runtime="${line%%|*}"
    model_line="${line#*|}"
    model="$(echo "$model_line" | sed -E 's/^[[:space:]]+//; s/ \([0-9A-Fa-f-]+\).*//')"
    os_short="${runtime:-(unknown)}"
    : "${model:=(unknown)}"

    if [[ -n "$app_id" ]]; then
      app_path="$(xcrun simctl get_app_container "$target" "$app_id" app 2>/dev/null || true)"
      if [[ -n "$app_path" && -f "$app_path/Info.plist" ]]; then
        [[ -n "$app_version" ]] || app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Info.plist" 2>/dev/null || true)"
        [[ -n "$app_build" ]] || app_build="$(plutil -extract CFBundleVersion raw -o - "$app_path/Info.plist" 2>/dev/null || true)"
      fi
    fi
    ;;
  android)
    adb_cmd=(adb)
    if [[ "$target" != "-" && -n "$target" ]]; then
      adb_cmd+=(-s "$target")
    fi
    model="$("${adb_cmd[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
    avd="$("${adb_cmd[@]}" shell getprop ro.boot.qemu.avd_name 2>/dev/null | tr -d '\r' || true)"
    rel="$("${adb_cmd[@]}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || true)"
    sdk="$("${adb_cmd[@]}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$avd" ]] && model="$avd ($model)"
    : "${model:=(unknown)}"
    if [[ -n "$rel" ]]; then
      os_short="Android $rel (API $sdk)"
    else
      os_short="(unknown)"
    fi
    ;;
esac

: "${app_id:=(unknown)}"
: "${app_version:=(unknown)}"
: "${app_build:=(unknown)}"
: "${plan_hash:=(none)}"

out="$dir/summary.md"
{
  echo "# $device_label · $locale"
  echo
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Model | $model |"
  echo "| OS | $os_short |"
  echo "| Resolution | $resolution |"
  echo "| Orientation | $orientation |"
  echo "| Locale | $locale |"
  echo "| App ID | \`$app_id\` |"
  echo "| App version | $app_version |"
  echo "| App build | $app_build |"
  echo "| Capture plan | \`$plan_hash\` |"
  echo "| Simulator metadata override | $simulator_override |"
  echo "| Validation | $validation |"
  echo "| Last captured | $captured |"
  if [[ "$screen_row_count" -gt 0 ]]; then
    echo
    echo "## Screens"
    echo
    echo "| NN | Slug | Deep link |"
    echo "| --- | --- | --- |"
    for row in "${screen_rows[@]}"; do
      read -r nn slug path <<<"$row"
      echo "| $nn | $slug | \`$path\` |"
    done
  fi
} >"$out"

echo "wrote $out"
