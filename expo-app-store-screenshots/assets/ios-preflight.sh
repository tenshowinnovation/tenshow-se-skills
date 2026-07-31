#!/usr/bin/env bash
# Compare an Expo project's intended iOS capabilities with an installed
# Simulator app and print one machine-readable decision as JSON.
#
# Usage:
#   bash ios-preflight.sh \
#     --project path/to/app \
#     --udid <simulator-udid> \
#     --bundle-id com.example.app \
#     --device iphone|ipad \
#     --orientation PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: ios-preflight.sh --project DIR --udid UDID --bundle-id ID
                        --device iphone|ipad
                        --orientation PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT
EOF
}

project=""
udid=""
bundle_id=""
device=""
orientation=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --udid) udid="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    --device) device="${2:-}"; shift 2 ;;
    --orientation) orientation="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$project" || -z "$udid" || -z "$bundle_id" || -z "$device" || -z "$orientation" ]]; then
  usage
  exit 2
fi
if [[ ! -d "$project" ]]; then
  echo "error: project directory does not exist: $project" >&2
  exit 2
fi
if [[ "$device" != "iphone" && "$device" != "ipad" ]]; then
  echo "error: --device must be iphone or ipad" >&2
  exit 2
fi
case "$orientation" in
  PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT) ;;
  *) echo "error: invalid --orientation: $orientation" >&2; exit 2 ;;
esac

project_abs="$(cd "$project" && pwd)"

for command_name in jq plutil xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 2
  fi
done

json_array() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

emit() {
  local decision="$1"
  local source_json="$2"
  local installed_json="$3"
  shift 3
  local reasons_json
  reasons_json=$(json_array "$@")
  jq -n \
    --arg decision "$decision" \
    --arg project "$project_abs" \
    --arg udid "$udid" \
    --arg bundleId "$bundle_id" \
    --arg device "$device" \
    --arg orientation "$orientation" \
    --argjson source "$source_json" \
    --argjson installed "$installed_json" \
    --argjson reasons "$reasons_json" \
    '{
      decision: $decision,
      project: $project,
      udid: $udid,
      bundleId: $bundleId,
      requested: {device: $device, orientation: $orientation},
      source: $source,
      installed: $installed,
      reasons: $reasons
    }'
}

orientation_allowed_filter='
  def orientations:
    if $device == "ipad" and ((.["UISupportedInterfaceOrientations~ipad"] // []) | length) > 0
    then .["UISupportedInterfaceOrientations~ipad"]
    else (.UISupportedInterfaceOrientations // [])
    end;
  def array_allows:
    if $orientation == "PORTRAIT"
    then any(orientations[]?; . == "UIInterfaceOrientationPortrait" or . == "UIInterfaceOrientationPortraitUpsideDown")
    elif $orientation == "LANDSCAPE_LEFT"
    then any(orientations[]?; . == "UIInterfaceOrientationLandscapeLeft")
    else any(orientations[]?; . == "UIInterfaceOrientationLandscapeRight")
    end;
  def mask_allows:
    (.EXDefaultScreenOrientationMask // "") as $mask
    | if $mask == "" or $mask == "UIInterfaceOrientationMaskAll" or $mask == "UIInterfaceOrientationMaskAllButUpsideDown"
      then true
      elif $orientation == "PORTRAIT"
      then ($mask == "UIInterfaceOrientationMaskPortrait" or $mask == "UIInterfaceOrientationMaskPortraitUpsideDown")
      elif $orientation == "LANDSCAPE_LEFT"
      then ($mask == "UIInterfaceOrientationMaskLandscape" or $mask == "UIInterfaceOrientationMaskLandscapeLeft")
      else ($mask == "UIInterfaceOrientationMaskLandscape" or $mask == "UIInterfaceOrientationMaskLandscapeRight")
      end;
  array_allows and mask_allows
'

config_json=""
if ! command -v npx >/dev/null 2>&1; then
  emit \
    "manual-check-required" \
    '{}' \
    '{}' \
    "A project-local Expo CLI is unavailable; inspect the native project and installed Info.plist manually."
  exit 0
fi
if ! config_json=$(cd "$project_abs" && npx --no-install expo config --type introspect --json 2>/dev/null); then
  emit \
    "manual-check-required" \
    '{}' \
    '{}' \
    "Expo config introspection failed; inspect the native project and installed Info.plist manually."
  exit 0
fi
if ! jq -e '._internal.modResults.ios.infoPlist | type == "object"' >/dev/null 2>&1 <<<"$config_json"; then
  emit \
    "manual-check-required" \
    '{}' \
    '{}' \
    "Expo introspection did not expose the generated iOS Info.plist."
  exit 0
fi

source_info=$(jq -c '._internal.modResults.ios.infoPlist' <<<"$config_json")
source_summary=$(jq -c '{
  version: (.ios.version // .version // null),
  buildNumber: (.ios.buildNumber // ._internal.modResults.ios.infoPlist.CFBundleVersion // null),
  supportsTablet: (.ios.supportsTablet // false),
  isTabletOnly: (.ios.isTabletOnly // false),
  deviceFamily:
    (if (.ios.isTabletOnly // false) then [2]
     elif (.ios.supportsTablet // false) then [1, 2]
     else [1]
     end),
  infoPlist: {
    UISupportedInterfaceOrientations: (._internal.modResults.ios.infoPlist.UISupportedInterfaceOrientations // []),
    "UISupportedInterfaceOrientations~ipad": (._internal.modResults.ios.infoPlist["UISupportedInterfaceOrientations~ipad"] // []),
    EXDefaultScreenOrientationMask: (._internal.modResults.ios.infoPlist.EXDefaultScreenOrientationMask // null),
    UIRequiresFullScreen: (._internal.modResults.ios.infoPlist.UIRequiresFullScreen // null)
  }
}' <<<"$config_json")

source_device_allowed=true
if [[ "$device" == "ipad" ]]; then
  source_device_allowed=$(jq -r '(.ios.supportsTablet // false) or (.ios.isTabletOnly // false)' <<<"$config_json")
else
  source_device_allowed=$(jq -r '(.ios.isTabletOnly // false) | not' <<<"$config_json")
fi
source_orientation_allowed=false
if jq -e \
  --arg device "$device" \
  --arg orientation "$orientation" \
  "$orientation_allowed_filter" >/dev/null 2>&1 <<<"$source_info"; then
  source_orientation_allowed=true
fi

source_reasons=()
if [[ "$source_device_allowed" != "true" ]]; then
  source_reasons+=("The evaluated Expo config does not support the requested device family; update source configuration before rebuilding.")
fi
if [[ "$source_orientation_allowed" != "true" ]]; then
  source_reasons+=("The evaluated Expo config does not support the requested orientation; update source configuration before rebuilding.")
fi
if [[ ${#source_reasons[@]} -gt 0 ]]; then
  emit "rebuild-required" "$source_summary" '{}' "${source_reasons[@]}"
  exit 0
fi

app_path=""
if ! app_path=$(xcrun simctl get_app_container "$udid" "$bundle_id" app 2>/dev/null); then
  emit \
    "rebuild-required" \
    "$source_summary" \
    '{}' \
    "The app is not installed on the requested simulator."
  exit 0
fi

info_plist="$app_path/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  emit \
    "manual-check-required" \
    "$source_summary" \
    '{}' \
    "The installed app container has no readable Info.plist."
  exit 0
fi
installed_info=$(plutil -convert json -o - "$info_plist")
installed_summary=$(jq -c --arg appPath "$app_path" '{
  appPath: $appPath,
  bundleId: (.CFBundleIdentifier // null),
  version: (.CFBundleShortVersionString // null),
  buildNumber: (.CFBundleVersion // null),
  deviceFamily:
    (if (.UIDeviceFamily // []) | type == "array"
     then (.UIDeviceFamily // [])
     elif .UIDeviceFamily == null
     then []
     else [.UIDeviceFamily]
     end),
  infoPlist: {
    UISupportedInterfaceOrientations: (.UISupportedInterfaceOrientations // []),
    "UISupportedInterfaceOrientations~ipad": (.["UISupportedInterfaceOrientations~ipad"] // []),
    EXDefaultScreenOrientationMask: (.EXDefaultScreenOrientationMask // null),
    UIRequiresFullScreen: (.UIRequiresFullScreen // null)
  }
}' <<<"$installed_info")

installed_bundle=$(jq -r '.bundleId // ""' <<<"$installed_summary")
source_version=$(jq -r '.version // ""' <<<"$source_summary")
source_build=$(jq -r '.buildNumber // "" | tostring' <<<"$source_summary")
installed_version=$(jq -r '.version // ""' <<<"$installed_summary")
installed_build=$(jq -r '.buildNumber // "" | tostring' <<<"$installed_summary")

stale_reasons=()
if [[ "$installed_bundle" != "$bundle_id" ]]; then
  stale_reasons+=("The installed bundle identifier does not match the requested app.")
fi
if [[ -n "$source_version" && -n "$installed_version" && "$source_version" != "$installed_version" ]]; then
  stale_reasons+=("The installed marketing version differs from the evaluated Expo config.")
fi
if [[ -n "$source_build" && -n "$installed_build" && "$source_build" != "$installed_build" ]]; then
  stale_reasons+=("The installed build number differs from the evaluated Expo config.")
fi
if [[ ${#stale_reasons[@]} -gt 0 ]]; then
  emit "rebuild-required" "$source_summary" "$installed_summary" "${stale_reasons[@]}"
  exit 0
fi

installed_device_allowed=false
family_value=1
[[ "$device" == "ipad" ]] && family_value=2
if jq -e --argjson family "$family_value" '.deviceFamily | index($family) != null' >/dev/null <<<"$installed_summary"; then
  installed_device_allowed=true
fi
installed_orientation_allowed=false
if jq -e \
  --arg device "$device" \
  --arg orientation "$orientation" \
  "$orientation_allowed_filter" >/dev/null 2>&1 <<<"$(jq -c '.infoPlist' <<<"$installed_summary")"; then
  installed_orientation_allowed=true
fi

capability_reasons=()
if [[ "$installed_device_allowed" != "true" ]]; then
  capability_reasons+=("The installed simulator app does not include the requested device family.")
fi
if [[ "$installed_orientation_allowed" != "true" ]]; then
  capability_reasons+=("The installed simulator app does not allow the requested orientation.")
fi
if [[ ${#capability_reasons[@]} -gt 0 ]]; then
  capability_reasons+=("Confirm the installed native build is current before using a temporary simulator-only metadata override.")
  emit "simulator-override-candidate" "$source_summary" "$installed_summary" "${capability_reasons[@]}"
  exit 0
fi

emit \
  "direct" \
  "$source_summary" \
  "$installed_summary" \
  "The evaluated source configuration and installed simulator metadata support the requested capture."
