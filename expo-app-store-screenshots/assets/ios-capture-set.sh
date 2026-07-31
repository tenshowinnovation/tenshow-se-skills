#!/usr/bin/env bash
# Capture one or more iOS screenshot sets from a deterministic JSON plan.
#
# Usage:
#   bash ios-capture-set.sh capture-plan.json \
#     [--device NAME] [--state NAME|all] [--resume] \
#     [--assume-state NAME]...

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: ios-capture-set.sh PLAN.json
       [--device NAME]
       [--state NAME|all]
       [--resume]
       [--assume-state NAME]...
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

plan="$1"
shift
device_filter=""
state_filter="all"
resume=false
assumed_states=()
assumed_state_count=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_filter="${2:-}"; shift 2 ;;
    --state) state_filter="${2:-}"; shift 2 ;;
    --resume) resume=true; shift ;;
    --assume-state)
      assumed_states+=("${2:-}")
      assumed_state_count=$((assumed_state_count + 1))
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -f "$plan" ]]; then
  echo "error: capture plan does not exist: $plan" >&2
  exit 2
fi
for command_name in jq magick maestro shasum xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 2
  fi
done
if ! jq -e '
  (.locale | type == "string" and length > 0)
  and (.app.scheme | type == "string" and length > 0)
  and (.app.iosBundleId | type == "string" and length > 0)
  and (.devices | type == "array" and length > 0)
  and (.scenes | type == "array" and length > 0)
' "$plan" >/dev/null; then
  echo "error: capture plan is missing locale, app identity, devices, or scenes" >&2
  exit 2
fi

plan_abs="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"
plan_dir="$(dirname "$plan_abs")"
plan_hash="$(shasum -a 256 "$plan_abs" | awk '{print $1}')"
locale="$(jq -r '.locale' "$plan_abs")"
output_root="$(jq -r '.outputRoot // "screenshots"' "$plan_abs")"
scheme="$(jq -r '.app.scheme' "$plan_abs")"
app_id="$(jq -r '.app.iosBundleId' "$plan_abs")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$locale" == */* ]]; then
  echo "error: locale must be a single directory name" >&2
  exit 2
fi
if [[ "$output_root" != /* ]]; then
  output_root="$plan_dir/$output_root"
fi

contains_value() {
  local wanted="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$wanted" ]] && return 0
  done
  return 1
}

resolve_plan_path() {
  local value="$1"
  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$plan_dir" "$value"
  fi
}

capture_is_valid() {
  local state_file="$1"
  local key="$2"
  local output_file="$3"
  local target_size="$4"
  [[ -f "$state_file" && -f "$output_file" ]] || return 1
  jq -e \
    --arg planHash "$plan_hash" \
    --arg key "$key" \
    --arg output "$output_file" \
    '.planHash == $planHash and .captures[$key].output == $output' \
    "$state_file" >/dev/null 2>&1 || return 1
  [[ "$(magick identify -format '%wx%h' "$output_file" 2>/dev/null)" == "$target_size" ]]
}

matching_devices=0
while IFS= read -r device_json; do
  device_name="$(jq -r '.name // empty' <<<"$device_json")"
  udid="$(jq -r '.udid // empty' <<<"$device_json")"
  orientation="$(jq -r '.orientation // "PORTRAIT"' <<<"$device_json")"
  target_size="$(jq -r '.targetSize // empty' <<<"$device_json")"

  if [[ -n "$device_filter" && "$device_name" != "$device_filter" ]]; then
    continue
  fi
  matching_devices=$((matching_devices + 1))
  if [[ ! "$device_name" =~ ^[a-z0-9][a-z0-9-]*$ || -z "$udid" || ! "$target_size" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "error: invalid device entry in capture plan: $device_json" >&2
    exit 2
  fi
  case "$orientation" in
    PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT) ;;
    *) echo "error: invalid orientation for $device_name: $orientation" >&2; exit 2 ;;
  esac

  output_dir="$output_root/$locale/$device_name"
  review_dir="$output_root/$locale/_review"
  state_file="$review_dir/$device_name.capture-state.json"
  mkdir -p "$output_dir" "$review_dir"

  simulator_state=$(
    xcrun simctl list devices -j 2>/dev/null \
      | jq -r --arg udid "$udid" '[.devices[][] | select(.udid == $udid)][0].state // empty'
  )
  case "$simulator_state" in
    Booted) ;;
    Shutdown)
      xcrun simctl boot "$udid"
      xcrun simctl bootstatus "$udid" -b
      ;;
    *) echo "error: simulator not found or unavailable: $udid" >&2; exit 2 ;;
  esac

  if [[ ! -f "$state_file" ]] || ! jq -e --arg hash "$plan_hash" '.planHash == $hash' "$state_file" >/dev/null 2>&1; then
    state_tmp="$(mktemp "$review_dir/.capture-state.XXXXXX")"
    jq -n \
      --arg planHash "$plan_hash" \
      --arg device "$device_name" \
      --arg udid "$udid" \
      '{planHash: $planHash, device: $device, udid: $udid, captures: {}}' >"$state_tmp"
    mv -f "$state_tmp" "$state_file"
  fi

  bash "$script_dir/ios-status-bar.sh" "$udid"

  states_order=()
  states_order_count=0
  while IFS= read -r scene_json; do
    scene_state="$(jq -r '.state // empty' <<<"$scene_json")"
    if [[ -z "$scene_state" ]]; then
      echo "error: every scene must declare a state" >&2
      exit 2
    fi
    if [[ "$state_filter" != "all" && "$scene_state" != "$state_filter" ]]; then
      continue
    fi
    if [[ "$states_order_count" -eq 0 ]] || ! contains_value "$scene_state" "${states_order[@]}"; then
      states_order+=("$scene_state")
      states_order_count=$((states_order_count + 1))
    fi
  done < <(jq -c '.scenes[]' "$plan_abs")

  if [[ "$states_order_count" -eq 0 ]]; then
    echo "error: no scenes matched state '$state_filter'" >&2
    exit 2
  fi

  for scene_state in "${states_order[@]}"; do
    pending=0
    while IFS= read -r scene_json; do
      [[ "$(jq -r '.state' <<<"$scene_json")" == "$scene_state" ]] || continue
      nn="$(jq -r '.nn // empty | tostring' <<<"$scene_json")"
      slug="$(jq -r '.slug // empty' <<<"$scene_json")"
      if [[ ! "$nn" =~ ^[0-9][0-9]$ || ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "error: invalid scene number or slug: $scene_json" >&2
        exit 2
      fi
      output_file="$output_dir/$nn-$device_name-$slug.png"
      key="$nn-$slug"
      if [[ "$resume" != "true" ]] || ! capture_is_valid "$state_file" "$key" "$output_file" "$target_size"; then
        pending=$((pending + 1))
      fi
    done < <(jq -c '.scenes[]' "$plan_abs")

    if [[ "$pending" -eq 0 ]]; then
      echo "resume $device_name/$scene_state: all captures already valid"
      continue
    fi

    state_flow="$(jq -r --arg state "$scene_state" '.states[$state].prepareFlow // empty' "$plan_abs")"
    if [[ -n "$state_flow" ]]; then
      state_flow="$(resolve_plan_path "$state_flow")"
      if [[ ! -f "$state_flow" ]]; then
        echo "error: state flow does not exist: $state_flow" >&2
        exit 2
      fi
      maestro --no-ansi --device "$udid" test -e "APP_ID=$app_id" "$state_flow"
    elif [[ "$assumed_state_count" -eq 0 ]] || ! contains_value "$scene_state" "${assumed_states[@]}"; then
      echo "error: state '$scene_state' has no prepareFlow" >&2
      echo "       add a state flow or pass --assume-state '$scene_state'" >&2
      exit 2
    fi

    while IFS= read -r scene_json; do
      [[ "$(jq -r '.state' <<<"$scene_json")" == "$scene_state" ]] || continue
      nn="$(jq -r '.nn | tostring' <<<"$scene_json")"
      slug="$(jq -r '.slug' <<<"$scene_json")"
      path="$(jq -r '.path // empty' <<<"$scene_json")"
      if [[ -z "$path" ]]; then
        echo "error: scene $nn-$slug has no path" >&2
        exit 2
      fi
      output_file="$output_dir/$nn-$device_name-$slug.png"
      key="$nn-$slug"

      if [[ "$resume" == "true" ]] && capture_is_valid "$state_file" "$key" "$output_file" "$target_size"; then
        echo "resume $output_file"
        continue
      fi

      if [[ "$path" == *"://"* ]]; then
        deep_link="$path"
      else
        [[ "$path" == /* ]] || path="/$path"
        deep_link="$scheme://$path"
      fi

      capture_args=(
        --udid "$udid"
        --url "$deep_link"
        --output "$output_file"
        --app-id "$app_id"
        --orientation "$orientation"
        --target-size "$target_size"
      )

      scene_flow="$(jq -r '.prepareFlow // empty' <<<"$scene_json")"
      if [[ -n "$scene_flow" ]]; then
        scene_flow="$(resolve_plan_path "$scene_flow")"
        capture_args+=(--prepare-flow "$scene_flow")
      fi
      ready_id="$(jq -r '.readyId // empty' <<<"$scene_json")"
      ready_text="$(jq -r '.readyText // empty' <<<"$scene_json")"
      [[ -z "$ready_id" ]] || capture_args+=(--ready-id "$ready_id")
      [[ -z "$ready_text" ]] || capture_args+=(--ready-text "$ready_text")
      while IFS= read -r hidden_text; do
        [[ -z "$hidden_text" ]] || capture_args+=(--not-visible-text "$hidden_text")
      done < <(jq -r '
        .notVisibleText // []
        | if type == "array" then .[] else . end
      ' <<<"$scene_json")

      bash "$script_dir/ios-capture.sh" "${capture_args[@]}"

      checksum="$(shasum -a 256 "$output_file" | awk '{print $1}')"
      captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      state_tmp="$(mktemp "$review_dir/.capture-state.XXXXXX")"
      jq \
        --arg key "$key" \
        --arg output "$output_file" \
        --arg size "$target_size" \
        --arg checksum "$checksum" \
        --arg capturedAt "$captured_at" \
        '.captures[$key] = {
          output: $output,
          size: $size,
          sha256: $checksum,
          capturedAt: $capturedAt
        }' "$state_file" >"$state_tmp"
      mv -f "$state_tmp" "$state_file"
    done < <(jq -c '.scenes[]' "$plan_abs")
  done
done < <(jq -c '.devices[]' "$plan_abs")

if [[ "$matching_devices" -eq 0 ]]; then
  echo "error: no device matched '${device_filter:-all}'" >&2
  exit 2
fi
