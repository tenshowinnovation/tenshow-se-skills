#!/usr/bin/env bash
# Deterministic fixture tests for expo-app-store-screenshots v0.3.0.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
skill_dir="$repo_root/expo-app-store-screenshots"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-skill-tests.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

for command_name in jq magick plutil shasum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing test dependency: $command_name"
done

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
real_magick="$(command -v magick)"
export REAL_MAGICK="$real_magick"
export FAKE_APP_PATH="$tmp/Installed.app"
export FAKE_CONFIG_JSON="$tmp/expo-config.json"
export FAKE_STATE_FILE="$tmp/simulator-state"
export FAKE_LOG="$tmp/fake-tools.log"
export FAKE_SCREENSHOT_FLAG="$tmp/screenshot-failed"
export FAKE_SCREEN_SIZE="100x200"
printf '%s\n' "Booted" >"$FAKE_STATE_FILE"
: >"$FAKE_LOG"

cat >"$fake_bin/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_NPX_FAIL:-false}" == "true" ]]; then
  exit 1
fi
cat "$FAKE_CONFIG_JSON"
EOF

cat >"$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
echo "codesign $*" >>"$FAKE_LOG"
EOF

cat >"$fake_bin/maestro" <<'EOF'
#!/usr/bin/env bash
echo "maestro $*" >>"$FAKE_LOG"
EOF

cat >"$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "simctl" ]] || exit 2
command_name="${2:-}"
case "$command_name" in
  get_app_container)
    [[ "${FAKE_APP_MISSING:-false}" != "true" ]] || exit 1
    printf '%s\n' "$FAKE_APP_PATH"
    ;;
  install)
    echo "install $3 $4" >>"$FAKE_LOG"
    ;;
  list)
    state="$(cat "$FAKE_STATE_FILE")"
    printf '{"devices":{"iOS":[{"udid":"TEST-UDID","state":"%s"}]}}\n' "$state"
    ;;
  boot)
    printf '%s\n' "Booted" >"$FAKE_STATE_FILE"
    echo "boot $3" >>"$FAKE_LOG"
    ;;
  bootstatus|status_bar|openurl)
    echo "$command_name ${*:3}" >>"$FAKE_LOG"
    ;;
  io)
    if [[ "${4:-}" != "screenshot" ]]; then
      exit 2
    fi
    if [[ "${FAKE_SCREENSHOT_FAIL_ONCE:-false}" == "true" && ! -f "$FAKE_SCREENSHOT_FLAG" ]]; then
      touch "$FAKE_SCREENSHOT_FLAG"
      printf '%s\n' "Shutdown" >"$FAKE_STATE_FILE"
      exit 1
    fi
    echo "screenshot ${5:-}" >>"$FAKE_LOG"
    "$REAL_MAGICK" -size "$FAKE_SCREEN_SIZE" xc:'#0a7f5a' "${5:-}"
    ;;
  *)
    echo "unsupported fake xcrun command: $*" >&2
    exit 2
    ;;
esac
EOF

chmod +x "$fake_bin/npx" "$fake_bin/codesign" "$fake_bin/maestro" "$fake_bin/xcrun"
export PATH="$fake_bin:$PATH"

write_config() {
  cat >"$FAKE_CONFIG_JSON" <<'EOF'
{
  "version": "1.0.0",
  "ios": {
    "buildNumber": "1",
    "supportsTablet": true,
    "isTabletOnly": false
  },
  "_internal": {
    "modResults": {
      "ios": {
        "infoPlist": {
          "CFBundleVersion": "1",
          "EXDefaultScreenOrientationMask": "UIInterfaceOrientationMaskAllButUpsideDown",
          "UIRequiresFullScreen": true,
          "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
          ],
          "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
          ]
        }
      }
    }
  }
}
EOF
}

write_installed_plist() {
  local family_json="$1"
  local orientations_json="$2"
  local mask="$3"
  mkdir -p "$FAKE_APP_PATH"
  cat >"$FAKE_APP_PATH/Info.plist" <<EOF
{
  "CFBundleIdentifier": "com.example.app",
  "CFBundleShortVersionString": "1.0.0",
  "CFBundleVersion": "1",
  "UIDeviceFamily": $family_json,
  "UISupportedInterfaceOrientations": $orientations_json,
  "UISupportedInterfaceOrientations~ipad": $orientations_json,
  "EXDefaultScreenOrientationMask": "$mask"
}
EOF
}

write_config
write_installed_plist \
  '[1, 2]' \
  '["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]' \
  'UIInterfaceOrientationMaskAllButUpsideDown'

preflight_args=(
  --project "$tmp"
  --udid TEST-UDID
  --bundle-id com.example.app
  --device ipad
  --orientation LANDSCAPE_LEFT
)

decision="$(
  bash "$skill_dir/assets/ios-preflight.sh" "${preflight_args[@]}" \
    | jq -r '.decision'
)"
assert_eq "direct" "$decision" "direct preflight"

write_installed_plist \
  '[1]' \
  '["UIInterfaceOrientationPortrait"]' \
  'UIInterfaceOrientationMaskPortrait'
decision="$(
  bash "$skill_dir/assets/ios-preflight.sh" "${preflight_args[@]}" \
    | jq -r '.decision'
)"
assert_eq "simulator-override-candidate" "$decision" "override candidate preflight"

export FAKE_APP_MISSING=true
decision="$(
  bash "$skill_dir/assets/ios-preflight.sh" "${preflight_args[@]}" \
    | jq -r '.decision'
)"
assert_eq "rebuild-required" "$decision" "missing app preflight"
unset FAKE_APP_MISSING

export FAKE_NPX_FAIL=true
decision="$(
  bash "$skill_dir/assets/ios-preflight.sh" "${preflight_args[@]}" \
    | jq -r '.decision'
)"
assert_eq "manual-check-required" "$decision" "manual preflight"
unset FAKE_NPX_FAIL

override_session="$(
  bash "$skill_dir/assets/ios-simulator-override.sh" prepare \
    "${preflight_args[@]}" \
    --confirm-current-build
)"
[[ -d "$override_session/patched.app" ]] || fail "override session was not created"
patched_families="$(
  plutil -convert json -o - "$override_session/patched.app/Info.plist" \
    | jq -c '.UIDeviceFamily'
)"
assert_eq "[1,2]" "$patched_families" "patched device families"
bash "$skill_dir/assets/ios-simulator-override.sh" restore \
  --udid TEST-UDID \
  --session "$override_session"
[[ ! -e "$override_session" ]] || fail "override session was not removed"

routes_project="$tmp/routes-project"
mkdir -p \
  "$routes_project/app/(auth)" \
  "$routes_project/app/(legacy)" \
  "$routes_project/app/(app)/videos/[id]"
: >"$routes_project/app/(auth)/sign-in.tsx"
: >"$routes_project/app/(legacy)/sign-in.tsx"
: >"$routes_project/app/(app)/videos/[id]/practice.tsx"
: >"$routes_project/app/index.tsx"
routes_output="$tmp/routes.tsv"
routes_errors="$tmp/routes.err"
bash "$skill_dir/assets/detect-routes.sh" "$routes_project" \
  >"$routes_output" 2>"$routes_errors"
grep -F $'/sign-in\t(auth)\tapp/(auth)/sign-in.tsx' "$routes_output" >/dev/null \
  || fail "public route did not remove the route group"
grep -F '/videos/[id]/practice' "$routes_output" >/dev/null \
  || fail "dynamic route was not retained"
grep -F 'dynamic route needs concrete values' "$routes_errors" >/dev/null \
  || fail "dynamic route warning missing"
grep -F 'duplicate public route /sign-in' "$routes_errors" >/dev/null \
  || fail "duplicate route warning missing"

landscape_output="$tmp/landscape.png"
bash "$skill_dir/assets/ios-capture.sh" \
  --udid TEST-UDID \
  --url myapp:///practice \
  --output "$landscape_output" \
  --app-id com.example.app \
  --orientation LANDSCAPE_LEFT \
  --ready-id practice-current-line \
  --target-size 200x100
assert_eq "200x100" "$(magick identify -format '%wx%h' "$landscape_output")" "landscape normalization"

legacy_output="$tmp/legacy.png"
bash "$skill_dir/assets/ios-capture.sh" \
  TEST-UDID \
  myapp:///legacy \
  "$legacy_output" \
  0
assert_eq "100x200" "$(magick identify -format '%wx%h' "$legacy_output")" "legacy capture interface"

rm -f "$FAKE_SCREENSHOT_FLAG"
printf '%s\n' "Booted" >"$FAKE_STATE_FILE"
export FAKE_SCREENSHOT_FAIL_ONCE=true
recovery_output="$tmp/recovery.png"
bash "$skill_dir/assets/ios-capture.sh" \
  --udid TEST-UDID \
  --url myapp:///recovery \
  --output "$recovery_output" \
  --app-id com.example.app \
  --ready-id recovery-ready \
  --target-size 100x200
unset FAKE_SCREENSHOT_FAIL_ONCE
[[ -f "$recovery_output" ]] || fail "shutdown recovery did not produce a screenshot"
grep -F 'boot TEST-UDID' "$FAKE_LOG" >/dev/null || fail "shutdown recovery did not boot the simulator"

plan="$tmp/capture-plan.json"
cat >"$plan" <<'EOF'
{
  "locale": "zh-Hans",
  "outputRoot": "shots",
  "app": {
    "projectDir": ".",
    "scheme": "myapp",
    "iosBundleId": "com.example.app"
  },
  "devices": [
    {
      "name": "ipad-landscape",
      "udid": "TEST-UDID",
      "orientation": "LANDSCAPE_LEFT",
      "targetSize": "200x100"
    }
  ],
  "states": {},
  "scenes": [
    {
      "nn": "01",
      "slug": "practice",
      "path": "/practice",
      "state": "signed-in",
      "readyId": "practice-current-line"
    }
  ]
}
EOF

printf '%s\n' "Booted" >"$FAKE_STATE_FILE"
count_before="$(grep -c '^screenshot ' "$FAKE_LOG" || true)"
if bash "$skill_dir/assets/ios-capture-set.sh" "$plan" >/dev/null 2>&1; then
  fail "capture set accepted an unprepared state without --assume-state"
fi
bash "$skill_dir/assets/ios-capture-set.sh" "$plan" \
  --assume-state signed-in
count_after_first="$(grep -c '^screenshot ' "$FAKE_LOG" || true)"
[[ "$count_after_first" -gt "$count_before" ]] || fail "capture set did not capture"

bash "$skill_dir/assets/ios-capture-set.sh" "$plan" \
  --assume-state signed-in \
  --resume
count_after_resume="$(grep -c '^screenshot ' "$FAKE_LOG" || true)"
assert_eq "$count_after_first" "$count_after_resume" "same-plan resume"

jq '.revision = 2' "$plan" >"$tmp/changed-plan.json"
mv "$tmp/changed-plan.json" "$plan"
bash "$skill_dir/assets/ios-capture-set.sh" "$plan" \
  --assume-state signed-in \
  --resume
count_after_change="$(grep -c '^screenshot ' "$FAKE_LOG" || true)"
[[ "$count_after_change" -gt "$count_after_resume" ]] || fail "changed plan did not recapture"

bash "$skill_dir/assets/verify-screenshots.sh" \
  --plan "$plan" \
  --device ipad-landscape
contact_sheet="$tmp/shots/zh-Hans/_review/ipad-landscape-contact-sheet.png"
[[ -f "$contact_sheet" ]] || fail "contact sheet was not written outside the device folder"

summary_dir="$tmp/shots/zh-Hans/ipad-landscape"
bash "$skill_dir/assets/write-summary.sh" \
  ios TEST-UDID "$summary_dir" zh-Hans \
  --orientation LANDSCAPE_LEFT \
  --app-id com.example.app \
  --plan-hash test-plan-hash \
  --simulator-override yes \
  --validation passed \
  -- \
  "01 practice /practice"
grep -F '| Simulator metadata override | yes |' "$summary_dir/summary.md" >/dev/null \
  || fail "summary did not record simulator override"
grep -F '| Validation | passed |' "$summary_dir/summary.md" >/dev/null \
  || fail "summary did not record validation"

wrong_output="$tmp/shots/zh-Hans/ipad-landscape/01-ipad-landscape-practice.png"
magick -size 50x50 xc:red "$wrong_output"
if bash "$skill_dir/assets/verify-screenshots.sh" \
  --plan "$plan" \
  --device ipad-landscape >/dev/null 2>&1; then
  fail "wrong dimensions unexpectedly passed verification"
fi

duplicate_plan="$tmp/duplicate-plan.json"
cat >"$duplicate_plan" <<'EOF'
{
  "locale": "zh-Hans",
  "outputRoot": "duplicates",
  "app": {
    "projectDir": ".",
    "scheme": "myapp",
    "iosBundleId": "com.example.app"
  },
  "devices": [
    {
      "name": "ipad",
      "udid": "TEST-UDID",
      "orientation": "PORTRAIT",
      "targetSize": "100x200"
    }
  ],
  "states": {},
  "scenes": [
    {"nn": "01", "slug": "one", "path": "/one", "state": "signed-in"},
    {"nn": "02", "slug": "two", "path": "/two", "state": "signed-in"}
  ]
}
EOF
duplicate_dir="$tmp/duplicates/zh-Hans/ipad"
mkdir -p "$duplicate_dir"
magick -size 100x200 xc:blue "$duplicate_dir/01-ipad-one.png"
cp "$duplicate_dir/01-ipad-one.png" "$duplicate_dir/02-ipad-two.png"
duplicate_errors="$tmp/duplicate.err"
bash "$skill_dir/assets/verify-screenshots.sh" \
  --plan "$duplicate_plan" \
  --device ipad 2>"$duplicate_errors"
grep -F 'exact duplicate screenshots' "$duplicate_errors" >/dev/null \
  || fail "duplicate warning missing"

echo "PASS: expo-app-store-screenshots fixture tests"
