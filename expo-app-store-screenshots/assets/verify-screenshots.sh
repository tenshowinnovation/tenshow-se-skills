#!/usr/bin/env bash
# Validate one captured device set against capture-plan.json and build a review
# contact sheet outside the store-upload directory.
#
# Usage:
#   bash verify-screenshots.sh --plan capture-plan.json --device ipad
#   bash verify-screenshots.sh --plan capture-plan.json --device ipad --state signed-in

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-screenshots.sh --plan PLAN.json --device NAME [--state NAME|all]
EOF
}

plan=""
device_name=""
state_filter="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan="${2:-}"; shift 2 ;;
    --device) device_name="${2:-}"; shift 2 ;;
    --state) state_filter="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$plan" || -z "$device_name" || ! -f "$plan" ]]; then
  usage
  exit 2
fi
for command_name in jq magick shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 2
  fi
done

plan_abs="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"
plan_dir="$(dirname "$plan_abs")"
locale="$(jq -r '.locale' "$plan_abs")"
output_root="$(jq -r '.outputRoot // "screenshots"' "$plan_abs")"
if [[ "$output_root" != /* ]]; then
  output_root="$plan_dir/$output_root"
fi

device_json="$(jq -c --arg name "$device_name" '.devices[] | select(.name == $name)' "$plan_abs")"
if [[ -z "$device_json" ]]; then
  echo "error: device not found in capture plan: $device_name" >&2
  exit 2
fi
target_size="$(jq -r '.targetSize' <<<"$device_json")"
device_dir="$output_root/$locale/$device_name"
review_dir="$output_root/$locale/_review"
contact_sheet="$review_dir/$device_name-contact-sheet.png"
mkdir -p "$review_dir"

expected_names=()
while IFS= read -r scene_json; do
  scene_state="$(jq -r '.state' <<<"$scene_json")"
  if [[ "$state_filter" != "all" && "$scene_state" != "$state_filter" ]]; then
    continue
  fi
  nn="$(jq -r '.nn | tostring' <<<"$scene_json")"
  slug="$(jq -r '.slug' <<<"$scene_json")"
  expected_names+=("$nn-$device_name-$slug.png")
done < <(jq -c '.scenes[]' "$plan_abs")

if [[ ${#expected_names[@]} -eq 0 ]]; then
  echo "error: no scenes matched state '$state_filter'" >&2
  exit 2
fi
if [[ ! -d "$device_dir" ]]; then
  echo "error: screenshot directory does not exist: $device_dir" >&2
  exit 1
fi

failures=0
expected_list="$(mktemp -t expected-screenshots)"
actual_list="$(mktemp -t actual-screenshots)"
checksum_list="$(mktemp -t screenshot-checksums)"
cleanup() {
  rm -f "$expected_list" "$actual_list" "$checksum_list"
}
trap cleanup EXIT

printf '%s\n' "${expected_names[@]}" | sort >"$expected_list"
find "$device_dir" -maxdepth 1 -type f -name '*.png' -exec basename {} \; | sort >"$actual_list"

if ! diff -u "$expected_list" "$actual_list"; then
  echo "error: screenshot filenames do not match the capture plan" >&2
  failures=$((failures + 1))
fi

valid_files=()
for expected_name in "${expected_names[@]}"; do
  file="$device_dir/$expected_name"
  if [[ ! -f "$file" ]]; then
    echo "error: missing screenshot: $file" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! dimensions=$(magick identify -format '%wx%h' "$file" 2>/dev/null); then
    echo "error: unreadable PNG: $file" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ "$dimensions" != "$target_size" ]]; then
    echo "error: $expected_name is $dimensions, expected $target_size" >&2
    failures=$((failures + 1))
    continue
  fi
  checksum="$(shasum -a 256 "$file" | awk '{print $1}')"
  printf '%s\t%s\n' "$checksum" "$expected_name" >>"$checksum_list"
  valid_files+=("$file")
done

if [[ -s "$checksum_list" ]]; then
  awk -F '\t' '
    {
      count[$1] += 1
      names[$1] = names[$1] (names[$1] ? ", " : "") $2
    }
    END {
      for (checksum in count) {
        if (count[checksum] > 1) {
          print "warning: exact duplicate screenshots: " names[checksum] > "/dev/stderr"
        }
      }
    }
  ' "$checksum_list"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "verification failed with $failures error(s)" >&2
  exit 1
fi

magick "${valid_files[@]}" \
  -thumbnail '360x360>' \
  -bordercolor white \
  -border '16x16' \
  +append \
  "$contact_sheet"

echo "verified ${#valid_files[@]} screenshot(s) at $target_size"
echo "contact sheet: $contact_sheet"
