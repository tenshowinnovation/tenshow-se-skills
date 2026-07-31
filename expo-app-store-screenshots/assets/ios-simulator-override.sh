#!/usr/bin/env bash
# Install a temporary, simulator-only copy of an app whose device/orientation
# metadata is stale, then restore the original app after capture.
#
# Usage:
#   bash ios-simulator-override.sh prepare \
#     --project path/to/app --udid UDID --bundle-id ID \
#     --device ipad --orientation LANDSCAPE_LEFT \
#     --confirm-current-build
#
#   bash ios-simulator-override.sh restore --udid UDID --session /tmp/session

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ios-simulator-override.sh prepare --project DIR --udid UDID --bundle-id ID
      --device iphone|ipad
      --orientation PORTRAIT|LANDSCAPE_LEFT|LANDSCAPE_RIGHT
      --confirm-current-build

  ios-simulator-override.sh restore --udid UDID --session DIR
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

action="$1"
shift
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

plist_set_json() {
  local plist="$1"
  local key="$2"
  local value="$3"
  if plutil -type "$key" "$plist" >/dev/null 2>&1; then
    plutil -replace "$key" -json "$value" "$plist"
  else
    plutil -insert "$key" -json "$value" "$plist"
  fi
}

case "$action" in
  prepare)
    project=""
    udid=""
    bundle_id=""
    device=""
    orientation=""
    confirmed=false

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project) project="${2:-}"; shift 2 ;;
        --udid) udid="${2:-}"; shift 2 ;;
        --bundle-id) bundle_id="${2:-}"; shift 2 ;;
        --device) device="${2:-}"; shift 2 ;;
        --orientation) orientation="${2:-}"; shift 2 ;;
        --confirm-current-build) confirmed=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done

    if [[ -z "$project" || -z "$udid" || -z "$bundle_id" || -z "$device" || -z "$orientation" ]]; then
      usage
      exit 2
    fi
    if [[ "$confirmed" != "true" ]]; then
      echo "error: --confirm-current-build is required" >&2
      echo "       The override must not hide a stale native build." >&2
      exit 2
    fi
    for command_name in codesign jq npx plutil xcrun; do
      if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command not found: $command_name" >&2
        exit 2
      fi
    done

    preflight=$(
      bash "$script_dir/ios-preflight.sh" \
        --project "$project" \
        --udid "$udid" \
        --bundle-id "$bundle_id" \
        --device "$device" \
        --orientation "$orientation"
    )
    decision=$(jq -r '.decision' <<<"$preflight")
    if [[ "$decision" != "simulator-override-candidate" ]]; then
      echo "error: preflight decision is '$decision'; refusing simulator override" >&2
      jq -r '.reasons[]? | "       - " + .' <<<"$preflight" >&2
      exit 1
    fi

    project_abs="$(cd "$project" && pwd)"
    app_path=$(xcrun simctl get_app_container "$udid" "$bundle_id" app)
    config_json=$(cd "$project_abs" && npx --no-install expo config --type introspect --json 2>/dev/null)
    desired_info=$(jq -c '._internal.modResults.ios.infoPlist' <<<"$config_json")
    desired_family=$(jq -c '
      if (.ios.isTabletOnly // false) then [2]
      elif (.ios.supportsTablet // false) then [1, 2]
      else [1]
      end
    ' <<<"$config_json")

    session=$(mktemp -d "${TMPDIR:-/tmp}/ios-screenshot-override.XXXXXX")
    cleanup_on_error=true
    cleanup() {
      if [[ "$cleanup_on_error" == "true" && -n "${session:-}" && -d "$session" ]]; then
        rm -rf -- "$session"
      fi
    }
    trap cleanup EXIT

    cp -R "$app_path" "$session/original.app"
    cp -R "$app_path" "$session/patched.app"
    patched_plist="$session/patched.app/Info.plist"
    plist_set_json "$patched_plist" "UIDeviceFamily" "$desired_family"

    for key in \
      "UISupportedInterfaceOrientations" \
      "UISupportedInterfaceOrientations~ipad" \
      "EXDefaultScreenOrientationMask" \
      "UIRequiresFullScreen"; do
      value=$(jq -c --arg key "$key" 'if has($key) then .[$key] else empty end' <<<"$desired_info")
      if [[ -n "$value" ]]; then
        plist_set_json "$patched_plist" "$key" "$value"
      fi
    done

    codesign --force --deep --sign - "$session/patched.app" >/dev/null
    xcrun simctl install "$udid" "$session/patched.app"

    jq -n \
      --arg udid "$udid" \
      --arg bundleId "$bundle_id" \
      --arg project "$project_abs" \
      --arg device "$device" \
      --arg orientation "$orientation" \
      --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      '{
        udid: $udid,
        bundleId: $bundleId,
        project: $project,
        requested: {device: $device, orientation: $orientation},
        createdAt: $createdAt
      }' >"$session/session.json"

    cleanup_on_error=false
    trap - EXIT
    echo "installed temporary simulator metadata override for $bundle_id" >&2
    printf '%s\n' "$session"
    ;;

  restore)
    udid=""
    session=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --udid) udid="${2:-}"; shift 2 ;;
        --session) session="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done
    if [[ -z "$udid" || -z "$session" ]]; then
      usage
      exit 2
    fi
    if [[ "$(basename "$session")" != ios-screenshot-override.* ]]; then
      echo "error: refusing to remove a directory not created by this command: $session" >&2
      exit 2
    fi
    if [[ ! -f "$session/session.json" || ! -d "$session/original.app" ]]; then
      echo "error: invalid override session: $session" >&2
      exit 2
    fi
    session_udid=$(jq -r '.udid' "$session/session.json")
    if [[ "$session_udid" != "$udid" ]]; then
      echo "error: session belongs to simulator $session_udid, not $udid" >&2
      exit 2
    fi
    xcrun simctl install "$udid" "$session/original.app"
    rm -rf -- "$session"
    echo "restored original simulator app" >&2
    ;;

  -h|--help)
    usage
    ;;

  *)
    echo "error: action must be prepare or restore" >&2
    usage
    exit 2
    ;;
esac
