#!/usr/bin/env bash
# Deep-link into a screen on an iOS Simulator, wait for deterministic UI state,
# normalize orientation/size, and atomically publish the screenshot.
#
# Legacy usage (kept for compatibility):
#   bash ios-capture.sh <UDID> <URL> <OUTPUT_PATH> [SETTLE_SECONDS]
#
# Named usage:
#   bash ios-capture.sh --udid UDID --url URL --output PATH [options]
#
# Options:
#   --app-id ID
#   --orientation PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT
#   --prepare-flow FILE
#   --ready-id ID | --ready-text TEXT
#   --not-visible-text TEXT        repeatable
#   --target-size WIDTHxHEIGHT
#   --settle SECONDS

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ios-capture.sh <UDID> <URL> <OUTPUT_PATH> [SETTLE_SECONDS]

  ios-capture.sh --udid UDID --url URL --output PATH
      [--app-id ID]
      [--orientation PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT]
      [--prepare-flow FILE]
      [--ready-id ID | --ready-text TEXT]
      [--not-visible-text TEXT]...
      [--target-size WIDTHxHEIGHT]
      [--settle SECONDS]
EOF
}

udid=""
url=""
output=""
app_id=""
orientation="PORTRAIT"
orientation_explicit=false
prepare_flow=""
ready_id=""
ready_text=""
not_visible_texts=()
not_visible_count=0
target_size=""
settle="2"
named_mode=false

if [[ $# -gt 0 && "$1" != --* ]]; then
  if [[ $# -lt 3 || $# -gt 4 ]]; then
    usage
    exit 2
  fi
  udid="$1"
  url="$2"
  output="$3"
  settle="${4:-2}"
else
  named_mode=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --udid) udid="${2:-}"; shift 2 ;;
      --url) url="${2:-}"; shift 2 ;;
      --output) output="${2:-}"; shift 2 ;;
      --app-id) app_id="${2:-}"; shift 2 ;;
      --orientation) orientation="${2:-}"; orientation_explicit=true; shift 2 ;;
      --prepare-flow) prepare_flow="${2:-}"; shift 2 ;;
      --ready-id) ready_id="${2:-}"; shift 2 ;;
      --ready-text) ready_text="${2:-}"; shift 2 ;;
      --not-visible-text)
        not_visible_texts+=("${2:-}")
        not_visible_count=$((not_visible_count + 1))
        shift 2
        ;;
      --target-size) target_size="${2:-}"; shift 2 ;;
      --settle) settle="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done
fi

if [[ -z "$udid" || -z "$url" || -z "$output" ]]; then
  usage
  exit 2
fi
case "$orientation" in
  PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT) ;;
  *) echo "error: invalid orientation: $orientation" >&2; exit 2 ;;
esac
if [[ -n "$ready_id" && -n "$ready_text" ]]; then
  echo "error: --ready-id and --ready-text are mutually exclusive" >&2
  exit 2
fi
if [[ -n "$target_size" && ! "$target_size" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "error: --target-size must be WIDTHxHEIGHT" >&2
  exit 2
fi
if [[ ! "$settle" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "error: --settle must be a non-negative number" >&2
  exit 2
fi
if [[ -n "$prepare_flow" && ! -f "$prepare_flow" ]]; then
  echo "error: Maestro flow does not exist: $prepare_flow" >&2
  exit 2
fi

automation_used=false
if [[ "$orientation_explicit" == "true" || -n "$prepare_flow" || -n "$ready_id" || -n "$ready_text" || "$not_visible_count" -gt 0 ]]; then
  automation_used=true
fi
if [[ "$orientation_explicit" == "true" || -n "$ready_id" || -n "$ready_text" || "$not_visible_count" -gt 0 ]]; then
  if [[ -z "$app_id" ]]; then
    echo "error: --app-id is required for generated Maestro orientation/readiness flows" >&2
    exit 2
  fi
fi

for command_name in jq xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 2
  fi
done
if [[ "$automation_used" == "true" ]] && ! command -v maestro >/dev/null 2>&1; then
  echo "error: Maestro is required for orientation or readiness automation" >&2
  exit 2
fi
if [[ -n "$target_size" || "$orientation_explicit" == "true" ]] && ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick 'magick' is required for normalization" >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"
output_abs="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
screenshot_tmp="$(mktemp -t app-store-screenshot).png"
processed_tmp="$(mktemp -t app-store-screenshot-processed).png"
orientation_flow=""
readiness_flow=""

cleanup() {
  rm -f "$screenshot_tmp" "$processed_tmp"
  [[ -z "$orientation_flow" ]] || rm -f "$orientation_flow"
  [[ -z "$readiness_flow" ]] || rm -f "$readiness_flow"
}
trap cleanup EXIT

yaml_quote() {
  jq -Rn --arg value "$1" '$value'
}

if [[ "$orientation_explicit" == "true" ]]; then
  orientation_flow="$(mktemp -t screenshot-orientation).yaml"
  {
    printf 'appId: %s\n' "$(yaml_quote "$app_id")"
    printf '%s\n' '---'
    printf -- '- setOrientation: %s\n' "$orientation"
    printf '%s\n' '- waitForAnimationToEnd'
  } >"$orientation_flow"
fi

if [[ -n "$ready_id" || -n "$ready_text" || "$not_visible_count" -gt 0 ]]; then
  readiness_flow="$(mktemp -t screenshot-readiness).yaml"
  {
    printf 'appId: %s\n' "$(yaml_quote "$app_id")"
    printf '%s\n' '---'
    if [[ -n "$ready_id" ]]; then
      printf '%s\n' '- assertVisible:'
      printf '    id: %s\n' "$(yaml_quote "$ready_id")"
    elif [[ -n "$ready_text" ]]; then
      printf '%s\n' '- assertVisible:'
      printf '    text: %s\n' "$(yaml_quote "$ready_text")"
    fi
    if [[ "$not_visible_count" -gt 0 ]]; then
      for hidden_text in "${not_visible_texts[@]}"; do
        printf '%s\n' '- assertNotVisible:'
        printf '    text: %s\n' "$(yaml_quote "$hidden_text")"
      done
    fi
  } >"$readiness_flow"
fi

simulator_state() {
  xcrun simctl list devices -j 2>/dev/null \
    | jq -r --arg udid "$udid" '[.devices[][] | select(.udid == $udid)][0].state // empty'
}

ensure_booted() {
  local state
  booted_now=false
  state=$(simulator_state)
  case "$state" in
    Booted) return 0 ;;
    Shutdown)
      xcrun simctl boot "$udid"
      xcrun simctl bootstatus "$udid" -b
      booted_now=true
      ;;
    *)
      echo "error: simulator not found or unavailable: $udid" >&2
      return 1
      ;;
  esac
}

run_maestro_flow() {
  local flow="$1"
  local command_args=(maestro --no-ansi --device "$udid" test)
  if [[ -n "$app_id" ]]; then
    command_args+=(-e "APP_ID=$app_id")
  fi
  command_args+=("$flow")
  "${command_args[@]}"
}

perform_capture() {
  if ! xcrun simctl openurl "$udid" "$url"; then
    return 1
  fi
  if [[ -n "$orientation_flow" ]] && ! run_maestro_flow "$orientation_flow"; then
    return 1
  fi
  if [[ -n "$prepare_flow" ]] && ! run_maestro_flow "$prepare_flow"; then
    return 1
  fi
  if [[ -n "$readiness_flow" ]] && ! run_maestro_flow "$readiness_flow"; then
    return 1
  fi
  if [[ "$automation_used" != "true" ]]; then
    sleep "$settle"
  fi
  if ! xcrun simctl io "$udid" screenshot "$screenshot_tmp"; then
    return 70
  fi
}

booted_now=false
ensure_booted
if [[ "$booted_now" == "true" ]]; then
  bash "$script_dir/ios-status-bar.sh" "$udid"
fi
capture_rc=0
if perform_capture; then
  capture_rc=0
else
  capture_rc=$?
fi

if [[ "$capture_rc" -eq 70 ]]; then
  state_after_failure=$(simulator_state)
  if [[ "$state_after_failure" == "Shutdown" ]]; then
    echo "screenshot service stopped with the simulator; recovering current scene once" >&2
    ensure_booted
    bash "$script_dir/ios-status-bar.sh" "$udid"
    if perform_capture; then
      capture_rc=0
    else
      capture_rc=$?
    fi
  else
    echo "error: screenshot failed while simulator state is '${state_after_failure:-unknown}'" >&2
  fi
fi
if [[ "$capture_rc" -ne 0 ]]; then
  echo "error: capture failed for $url" >&2
  exit "$capture_rc"
fi

if [[ "$orientation_explicit" == "true" ]]; then
  dimensions=$(magick identify -format '%wx%h' "$screenshot_tmp")
  width="${dimensions%x*}"
  height="${dimensions#*x}"
  if [[ "$orientation" == LANDSCAPE_* && "$width" -lt "$height" ]]; then
    rotation="-90"
    [[ "$orientation" == "LANDSCAPE_RIGHT" ]] && rotation="90"
    magick "$screenshot_tmp" -rotate "$rotation" "$processed_tmp"
    mv -f "$processed_tmp" "$screenshot_tmp"
  elif [[ "$orientation" == "PORTRAIT" && "$width" -gt "$height" ]]; then
    echo "error: expected a portrait framebuffer but received $dimensions" >&2
    exit 1
  fi
fi

if [[ -n "$target_size" ]]; then
  dimensions=$(magick identify -format '%wx%h' "$screenshot_tmp")
  if [[ "$dimensions" != "$target_size" ]]; then
    magick "$screenshot_tmp" \
      -resize "${target_size}^" \
      -gravity center \
      -extent "$target_size" \
      "$processed_tmp"
    mv -f "$processed_tmp" "$screenshot_tmp"
  fi
  final_dimensions=$(magick identify -format '%wx%h' "$screenshot_tmp")
  if [[ "$final_dimensions" != "$target_size" ]]; then
    echo "error: normalized screenshot is $final_dimensions, expected $target_size" >&2
    exit 1
  fi
fi

mv -f "$screenshot_tmp" "$output_abs"
echo "captured $output_abs"
