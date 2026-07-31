---
name: expo-app-store-screenshots
description: Capture, normalize, verify, and upload App Store or Google Play screenshots for React Native and Expo apps. Drive iOS Simulator and Android devices through deep links; preflight installed iOS capabilities before rebuilding; automate authenticated and dynamic scenes with Maestro; support iPhone portrait plus iPad portrait/landscape; resume interrupted runs; and generate review contact sheets. Use for refreshing store screenshots, adding locales/devices/scenes, diagnosing `simctl` capture or orientation problems, or uploading screenshot folders to App Store Connect and Google Play.
license: MIT
metadata:
  author: "北京腾秀创智技术有限公司 (Tenshow Innovation)"
  organization: tenshowinnovation.com
  version: "0.3.0"
---

# App Store / Google Play screenshots

Capture store-ready screenshots without hard-coding app identity, credentials,
routes, or localized UI. Inspect the current app and installed binary before
choosing a build path.

## Core rule: inspect before rebuilding

For iOS, choose the shortest valid path:

1. Confirm the installed app visually matches current source.
2. Run `assets/ios-preflight.sh` for every requested device/orientation.
3. Follow its decision:
   - `direct`: capture with the installed app.
   - `simulator-override-candidate`: confirm native code is current, then use
     the temporary simulator override only if needed.
   - `rebuild-required`: update source configuration when indicated, then use
     the project's existing build command.
   - `manual-check-required`: inspect the native project and installed
     `Info.plist`.
4. If a required build fails, stop at the first useful native error. Do not add
   Hermes, CMake, architecture, cache, or retry workarounds to this skill.

Read [references/ios-automation.md](references/ios-automation.md) before an iOS
run that needs iPad landscape, Dev Client cleanup, authentication, dynamic UI,
resume, or a simulator metadata override.

## Output layout

```text
screenshots/<locale>/<device>/NN-<device>-<screen>.png
screenshots/<locale>/_review/<device>.capture-state.json
screenshots/<locale>/_review/<device>-contact-sheet.png
```

- Use a project-appropriate locale label such as `en-US`, `zh-CN`, or
  `zh-Hans`.
- Use `iphone`, `ipad`, `ipad-landscape`, `android-phone`, or
  `android-tablet` as device names.
- Use two-digit ordinals and kebab-case screen slugs.
- Keep `_review` outside device folders so upload helpers never include review
  artifacts.

## Common target dimensions

| Device | Target | Notes |
| --- | --- | --- |
| `iphone` | 1284×2778 | App Store 6.5-inch portrait slot |
| `ipad` | 2064×2752 | App Store 13-inch portrait |
| `ipad-landscape` | 2752×2064 | App Store 13-inch landscape |
| `android-phone` | 1440×3120 | Google Play phone |

Check current store requirements before adding another target. Apple lists
accepted portrait and landscape sizes in its
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Bundled commands

All commands live under `assets/`:

| Command | Purpose |
| --- | --- |
| [`detect-app-config.sh`](assets/detect-app-config.sh) | Detect scheme, iOS Bundle ID, and Android package. |
| [`detect-routes.sh`](assets/detect-routes.sh) | Print public Expo Router paths, route groups, and sources. |
| [`ios-preflight.sh`](assets/ios-preflight.sh) | Compare evaluated Expo iOS capabilities with an installed simulator app. |
| [`ios-simulator-override.sh`](assets/ios-simulator-override.sh) | Prepare and restore an explicit simulator-only metadata override. |
| [`ios-status-bar.sh`](assets/ios-status-bar.sh) | Lock or clear the iOS status bar. |
| [`ios-capture.sh`](assets/ios-capture.sh) | Capture one iOS scene with optional Maestro readiness and normalization. |
| [`ios-capture-set.sh`](assets/ios-capture-set.sh) | Execute a JSON capture plan with state preparation and resume. |
| [`android-status-bar.sh`](assets/android-status-bar.sh) | Enter or exit Android system UI demo mode. |
| [`android-capture.sh`](assets/android-capture.sh) | Deep-link and capture one Android screen. |
| [`resize.sh`](assets/resize.sh) | Resize and center-crop PNGs to a target size. |
| [`verify-screenshots.sh`](assets/verify-screenshots.sh) | Validate a planned device set and make a contact sheet. |
| [`write-summary.sh`](assets/write-summary.sh) | Record device, app, plan, override, and validation provenance. |
| [`upload-app-store.py`](assets/upload-app-store.py) | Upload one App Store locale/display-type folder. |
| [`upload-play-store.py`](assets/upload-play-store.py) | Upload one Google Play locale/image-type folder. |

Read each command header before using it.

## Capture workflow

### 1. Inspect identity and routes

```bash
eval "$(bash assets/detect-app-config.sh path/to/app)"
bash assets/detect-routes.sh path/to/app
```

`detect-routes.sh` removes Expo Router groups such as `(auth)` from the public
URL. Replace `[id]` and other dynamic segments with real values before capture.
Confirm auth redirects in the matching `_layout` files.

### 2. Select scenes and states

Separate signed-out and signed-in scenes. Prepare every state once per device.
Use project-owned Maestro flows for:

- accepting the first deep-link confirmation;
- dismissing Dev Client tutorials or refresh overlays;
- completing onboarding or authentication;
- granting permissions;
- scrolling, pausing media, or selecting stable dynamic content.

Keep credentials in the project test environment. Do not add them to this
skill or a reusable capture plan.

### 3. Preflight iOS capabilities

```bash
bash assets/ios-preflight.sh \
  --project path/to/app \
  --udid "$IPAD_UDID" \
  --bundle-id "$IOS_BUNDLE_ID" \
  --device ipad \
  --orientation LANDSCAPE_LEFT
```

Use `ios-simulator-override.sh` only for a confirmed
`simulator-override-candidate`. Restore the original app after capture and mark
the summary with `--simulator-override yes`.

### 4. Lock status bars

```bash
bash assets/ios-status-bar.sh "$IPHONE_UDID"
bash assets/ios-status-bar.sh "$IPAD_UDID"
bash assets/android-status-bar.sh enter
```

Always use explicit iOS UDIDs when multiple simulators are available.

### 5. Capture

Keep the legacy one-off iOS interface:

```bash
bash assets/ios-capture.sh \
  "$IPHONE_UDID" \
  "$APP_SCHEME:///settings" \
  screenshots/zh-Hans/iphone/05-iphone-settings.png
```

For deterministic iOS sets, create `capture-plan.json` using the schema in the
iOS automation reference:

```bash
bash assets/ios-capture-set.sh capture-plan.json
bash assets/ios-capture-set.sh capture-plan.json \
  --device ipad-landscape \
  --resume
```

If a state has no preparation flow, pass `--assume-state <name>` explicitly.
The runner does not guess whether a user is signed in.

For Android, retain the existing explicit capture loop:

```bash
bash assets/android-capture.sh \
  "$APP_SCHEME:///settings" \
  screenshots/zh-Hans/android-phone/05-android-phone-settings.png \
  "$ANDROID_PACKAGE"
```

Pass the Android serial through when multiple devices are attached.

### 6. Verify visually

```bash
bash assets/verify-screenshots.sh \
  --plan capture-plan.json \
  --device ipad-landscape
```

Treat missing, extra, corrupt, misnamed, rotated, or incorrectly sized images
as failures. Treat exact duplicate scenes as warnings. Inspect the generated
contact sheet for system prompts, Dev Client UI, loading indicators, incorrect
locale, stale data, and undesirable media frames.

Do not rely on command success or dimensions alone.

### 7. Record provenance

Run `write-summary.sh` after visual verification. Record:

- simulator model and OS;
- final resolution and orientation;
- app ID, version, and build;
- capture plan hash;
- simulator override status;
- validation result and screen list.

The extended options are documented in the iOS automation reference. Legacy
screen-row calls remain valid.

### 8. Clean up

- Restore a temporary simulator app override.
- Clear or retain the iOS status override according to project preference.
- Run `assets/android-status-bar.sh exit`.
- Stop a development server only if this run started it.
- Leave project source and unrelated working-tree changes untouched.

## Upload

### App Store Connect

Install `requests` and `pyjwt[crypto]`, then provide:

```bash
export ASC_KEY_ID=ABC1234567
export ASC_ISSUER_ID=11111111-2222-3333-4444-555555555555
export ASC_KEY_PATH=/secure/path/AuthKey_ABC1234567.p8
```

Upload one folder at a time:

```bash
python3 assets/upload-app-store.py \
  --app-id 1234567890 \
  --locale zh-Hans \
  --device ipad-landscape \
  --dir screenshots/zh-Hans/ipad-landscape
```

`ipad` and `ipad-landscape` map to the same 13-inch App Store display type.
Map output locale labels to App Store Connect locale codes explicitly; for
example, a `zh-CN` folder normally uploads as `zh-Hans`.

The command replaces the selected slot unless `--keep-existing` is passed. It
refuses to modify a non-editable app version.

### Google Play

Install `google-auth` and `requests`, then set `PLAY_CREDENTIALS` to a service
account JSON file:

```bash
python3 assets/upload-play-store.py \
  --package "$ANDROID_PACKAGE" \
  --locale zh-CN \
  --image-type phoneScreenshots \
  --dir screenshots/zh-CN/android-phone
```

Ensure the locale already exists in Play Console. Each Play screenshot slot
accepts at most eight images.

## Add a locale or scene

For a locale:

1. Switch the app/system locale.
2. Prime every device again because system prompts may be localized.
3. Change `locale` in the capture plan.
4. Capture, verify, and inspect one contact sheet per device.

For a scene:

1. Confirm the public deep link with `detect-routes.sh`.
2. Supply concrete dynamic route values.
3. Add the scene, auth state, readiness selector, and optional preparation
   flow.
4. Re-run affected devices with a changed plan; resume will recapture because
   the plan hash changed.
