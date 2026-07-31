# iOS deterministic screenshot automation

Use this reference when an iOS screenshot run needs multiple device shapes,
authenticated states, dynamic UI preparation, iPad landscape, resume, or a
temporary simulator metadata override.

## Contents

- [Preflight decisions](#preflight-decisions)
- [Temporary simulator override](#temporary-simulator-override)
- [Capture plan](#capture-plan)
- [Maestro flows](#maestro-flows)
- [Capture and resume](#capture-and-resume)
- [Verification and summary](#verification-and-summary)
- [Failure boundaries](#failure-boundaries)

## Preflight decisions

Run preflight before rebuilding:

```bash
bash assets/ios-preflight.sh \
  --project apps/app \
  --udid "$IPAD_UDID" \
  --bundle-id "$IOS_BUNDLE_ID" \
  --device ipad \
  --orientation LANDSCAPE_LEFT
```

The command writes JSON to stdout and returns one of four decisions:

| Decision | Action |
| --- | --- |
| `direct` | Use the installed app. |
| `simulator-override-candidate` | Visually confirm the native build is current, then optionally use the temporary override. |
| `rebuild-required` | Update source configuration if required, then use the project's normal build command. |
| `manual-check-required` | Inspect the native project and installed `Info.plist`; Expo introspection was unavailable or inconclusive. |

Preflight compares the evaluated Expo config with the installed simulator
bundle. It checks device families, supported orientations, the Expo screen
orientation mask, app version, and build number. It cannot prove that native
modules are current; visually launch the app before accepting an override
candidate.

Do not begin with `prebuild --clean` merely because an iPad opens in iPhone
compatibility mode. Determine whether source configuration, the installed
bundle, or both are stale first.

## Temporary simulator override

Use an override only when:

1. Preflight returns `simulator-override-candidate`.
2. The evaluated source config already supports the requested device and
   orientation.
3. The installed app's native code has been confirmed current.

Prepare and guarantee restoration:

```bash
OVERRIDE_SESSION=$(
  bash assets/ios-simulator-override.sh prepare \
    --project apps/app \
    --udid "$IPAD_UDID" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --device ipad \
    --orientation LANDSCAPE_LEFT \
    --confirm-current-build
)

restore_override() {
  bash assets/ios-simulator-override.sh restore \
    --udid "$IPAD_UDID" \
    --session "$OVERRIDE_SESSION"
}
trap restore_override EXIT
```

The prepare command copies the installed app into a temporary session, patches
only metadata produced by Expo introspection, signs the temporary copy, and
installs it on the selected simulator. Restore reinstalls the original app and
deletes the session.

This override is a capture aid. It does not prove that a shipping binary
supports iPad or landscape, and its use must be recorded in `summary.md`.

## Capture plan

Resolve relative `projectDir`, flow, and `outputRoot` paths from the directory
containing the plan.

```json
{
  "locale": "zh-Hans",
  "outputRoot": "screenshots",
  "app": {
    "projectDir": "apps/app",
    "scheme": "myapp",
    "iosBundleId": "com.example.myapp"
  },
  "devices": [
    {
      "name": "iphone",
      "udid": "IPHONE-UDID",
      "orientation": "PORTRAIT",
      "targetSize": "1284x2778"
    },
    {
      "name": "ipad",
      "udid": "IPAD-UDID",
      "orientation": "PORTRAIT",
      "targetSize": "2064x2752"
    },
    {
      "name": "ipad-landscape",
      "udid": "IPAD-UDID",
      "orientation": "LANDSCAPE_LEFT",
      "targetSize": "2752x2064"
    }
  ],
  "states": {
    "signed-out": {
      "prepareFlow": "flows/signed-out.yaml"
    },
    "signed-in": {
      "prepareFlow": "flows/signed-in.yaml"
    }
  },
  "scenes": [
    {
      "nn": "01",
      "slug": "sign-in",
      "path": "/sign-in",
      "state": "signed-out",
      "readyId": "auth-phone-entry-button",
      "notVisibleText": ["Refreshing…"]
    },
    {
      "nn": "02",
      "slug": "home",
      "path": "/",
      "state": "signed-in",
      "readyText": "Home"
    },
    {
      "nn": "03",
      "slug": "practice",
      "path": "/videos/example-id/practice",
      "state": "signed-in",
      "prepareFlow": "flows/practice.yaml",
      "readyText": "Current line"
    }
  ]
}
```

Rules:

- Use two-digit strings for `nn` and kebab-case for device names and slugs.
- Use concrete values for dynamic route parameters such as `[id]`.
- Use `PORTRAIT`, `LANDSCAPE_LEFT`, or `LANDSCAPE_RIGHT`.
- Put transient overlays in `notVisibleText`; the field accepts a string or an
  array.
- Keep credentials outside the skill and plan. Pass them to project-owned
  Maestro flows through their normal environment.

## Maestro flows

Target an explicit simulator. The scripts invoke Maestro as:

```bash
maestro --device "$UDID" test -e "APP_ID=$IOS_BUNDLE_ID" flow.yaml
```

Use state flows for one-time work such as accepting a system confirmation,
dismissing the Dev Client tutorial, completing onboarding, signing in, or
granting permission. Use scene flows for page-specific work such as scrolling,
pausing media, or selecting a stable tab.

Example scene flow:

```yaml
appId: ${APP_ID}
---
- scrollUntilVisible:
    element:
      id: "practice-current-line"
    direction: DOWN
- assertVisible:
    id: "practice-current-line"
- assertNotVisible: "Refreshing…"
```

Prefer accessibility IDs and assertions. Do not place project credentials,
localized system prompt coordinates, or arbitrary sleeps in the generic skill.

## Capture and resume

Capture every configured device and state:

```bash
bash assets/ios-capture-set.sh capture-plan.json
```

If a state intentionally has no preparation flow, confirm it explicitly:

```bash
bash assets/ios-capture-set.sh capture-plan.json \
  --device ipad \
  --state signed-in \
  --assume-state signed-in
```

Resume only captures produced by the same plan:

```bash
bash assets/ios-capture-set.sh capture-plan.json \
  --device ipad-landscape \
  --resume
```

Resume state lives at:

```text
screenshots/<locale>/_review/<device>.capture-state.json
```

A file is skipped only when the plan hash matches, the recorded output exists,
and its dimensions match the device target. Existing screenshots without a
matching state record are recaptured.

For a one-off screen, call `assets/ios-capture.sh` directly. Its legacy
positional interface remains supported. Use the named interface for Maestro
readiness, landscape normalization, and target sizing.

## Verification and summary

Verify a complete device set:

```bash
bash assets/verify-screenshots.sh \
  --plan capture-plan.json \
  --device ipad-landscape
```

The verifier fails on missing, unexpected, corrupt, misnamed, or incorrectly
sized PNGs. Exact duplicates are warnings. It writes the contact sheet under
`screenshots/<locale>/_review/`, outside upload directories.

After visually inspecting the contact sheet, write provenance:

```bash
bash assets/write-summary.sh ios "$IPAD_UDID" \
  screenshots/zh-Hans/ipad-landscape zh-Hans \
  --orientation LANDSCAPE_LEFT \
  --app-id "$IOS_BUNDLE_ID" \
  --plan-hash "$(shasum -a 256 capture-plan.json | awk '{print $1}')" \
  --simulator-override no \
  --validation passed \
  -- \
  "01 sign-in /sign-in" \
  "02 home /"
```

Set `--simulator-override yes` whenever the temporary app path was used.

## Failure boundaries

- If `simctl io screenshot` fails and the selected simulator changed to
  `Shutdown`, `ios-capture.sh` boots it, restores the clean status bar, and
  retries only that scene once.
- If screenshot capture fails while the simulator remains `Booted`, stop and
  report the error. Do not restart healthy simulators blindly.
- If a Maestro preparation or readiness assertion fails, stop before writing
  the output file.
- If a required native build fails, preserve the first useful error and move to
  the project's build troubleshooting workflow. Do not encode Hermes, CMake,
  architecture, cache, or retry hacks in this skill.
