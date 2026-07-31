#!/usr/bin/env bash
# Enumerate public Expo Router paths as:
#   <deep-link-path>\t<closest-route-group>\t<source-file>
#
# Route groups such as `(auth)` are removed from the public path. Dynamic
# segments remain visible and are reported on stderr because they need concrete
# values before capture.
#
# Usage:
#   bash detect-routes.sh <project-root>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <project-root>" >&2
  exit 2
fi

project_root="$1"
if [[ ! -d "$project_root" ]]; then
  echo "error: not a directory: $project_root" >&2
  exit 2
fi

if [[ -d "$project_root/app" ]]; then
  app_dir="$project_root/app"
elif [[ -d "$project_root/src/app" ]]; then
  app_dir="$project_root/src/app"
else
  echo "error: no app/ or src/app/ directory under $project_root" >&2
  exit 2
fi

project_root_abs="$(cd "$project_root" && pwd)"
app_dir_abs="$(cd "$app_dir" && pwd)"
routes_tmp="$(mktemp -t expo-routes)"
cleanup() {
  rm -f "$routes_tmp"
}
trap cleanup EXIT

while IFS= read -r file; do
  rel="${file#$app_dir_abs/}"
  noext="${rel%.tsx}"
  noext="${noext%.ts}"
  noext="${noext%.jsx}"
  noext="${noext%.js}"

  group="(root)"
  if [[ "$rel" == *"("*")"* ]]; then
    group=$(printf '%s\n' "$rel" | grep -oE '\([^/)]+\)' | tail -1 || true)
    group="${group:-(root)}"
  fi

  public_path=""
  IFS='/' read -r -a segments <<<"$noext"
  last_index=$((${#segments[@]} - 1))
  for index in "${!segments[@]}"; do
    segment="${segments[$index]}"
    if [[ "$segment" == \(*\) ]]; then
      continue
    fi
    if [[ "$index" -eq "$last_index" && "$segment" == "index" ]]; then
      continue
    fi
    public_path="$public_path/$segment"
  done
  [[ -n "$public_path" ]] || public_path="/"

  if [[ "$public_path" == *"["*"]"* ]]; then
    echo "warning: dynamic route needs concrete values before capture: $public_path" >&2
  fi

  file_rel="${file#$project_root_abs/}"
  printf '%s\t%s\t%s\n' "$public_path" "$group" "$file_rel" >>"$routes_tmp"
done < <(
  find "$app_dir_abs" -type f \
    \( -name '*.tsx' -o -name '*.ts' -o -name '*.jsx' -o -name '*.js' \) \
    -not -name '_*' \
    -not -name '+*' \
    -not -name '*.d.ts' \
    -not -name '*.test.*' \
    -not -name '*.spec.*' \
    | sort
)

awk -F '\t' '
  {
    count[$1] += 1
    sources[$1] = sources[$1] (sources[$1] ? ", " : "") $3
  }
  END {
    for (route in count) {
      if (count[route] > 1) {
        print "warning: duplicate public route " route ": " sources[route] > "/dev/stderr"
      }
    }
  }
' "$routes_tmp"

sort -t $'\t' -k1,1 -k3,3 "$routes_tmp"
