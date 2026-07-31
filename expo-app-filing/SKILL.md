---
name: expo-app-filing
description: Prepare China APP备案 / 火山引擎备案 information for Expo and EAS apps. Use when a user needs Bundle ID, Android package name, iOS 公钥, iOS SHA1指纹, Android 公钥, Android MD5指纹, EAS credentials, `eas init`, `eas.json`, Expo owner migration, or guidance filling APP备案 forms for Volcengine and similar Chinese filing consoles.
---

# Expo APP 备案

End-to-end runbook for Expo/EAS apps that need China APP filing fields: app identity, service domains, iOS distribution-certificate public key + SHA1, and Android release-keystore public key + MD5.

## Core workflow

1. Inspect the app config before running EAS:
   - Read `app.json`, `app.config.js`, or `app.config.ts`.
   - Confirm `expo.name`, `expo.slug`, `expo.owner`, `expo.ios.bundleIdentifier`, and `expo.android.package`.
   - If `owner` is missing and the user has multiple Expo accounts/orgs, add the correct `owner` before creating the EAS project. This prevents accidental `@personal/slug` project creation.
2. Verify EAS linkage:
   - Run `eas whoami` and confirm the target account/org is listed.
   - Run `eas init` only after `owner` is correct.
   - Run `eas project:info` and confirm `fullName` and `ID`.
   - If `eas credentials` fails with `eas.json could not be found`, add a minimal `eas.json` in the Expo app directory before continuing.
3. Configure credentials:
   - iOS: choose `Build Credentials`, then configure all required credentials or the `Distribution Certificate`.
   - Android: choose `Build Credentials`, then create/manage the release `Keystore`.
   - Do not use Expo Go, debug certificates, `android/app/debug.keystore`, or simulator-only credentials for filing.
4. Download credentials from EAS:
   - In `eas credentials`, choose `credentials.json: Upload/Download credentials between EAS servers and your local json`.
   - Download `credentials.json` plus the referenced iOS `.p12` and Android `.jks` files.
   - Ensure these files are ignored by git before proceeding.
5. Extract filing fields with `scripts/extract-eas-filing-features.sh`:
   ```bash
   /path/to/expo-app-filing/scripts/extract-eas-filing-features.sh /path/to/expo-app
   ```
   The script prints only备案-safe values: Bundle ID, Android package, iOS SHA1, Android MD5, and public-key moduli.
6. Fill the filing console:
   - Use `references/volcengine-app-filing-fields.md` for field-by-field guidance.
   - List the app's own service domains, not third-party SDK domains.
   - Select platforms that actually ship: usually iOS and Android.

## Minimal `eas.json`

Use this only when the project has no EAS config and the immediate goal is credentials/build setup:

```json
{
  "cli": {
    "version": ">= 18.5.0",
    "appVersionSource": "local"
  },
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal"
    },
    "preview": {
      "distribution": "internal"
    },
    "production": {
      "autoIncrement": true
    }
  }
}
```

If the repo already has build profiles, preserve them instead of replacing the file.

## Script

Use [`scripts/extract-eas-filing-features.sh`](scripts/extract-eas-filing-features.sh) after EAS credentials are downloaded.

Requirements:

- `jq`
- `openssl`
- `keytool` for Android extraction
- `npx expo config --json` is optional; the script falls back to `app.json`

The script expects the common EAS credentials layout:

```text
credentials.json
credentials/ios/dist-cert.p12
credentials/android/keystore.jks
```

It also follows paths recorded in `credentials.json`, so custom download locations work as long as paths are relative to the app directory or absolute.

## Filing fields reference

Read [`references/volcengine-app-filing-fields.md`](references/volcengine-app-filing-fields.md) when the user is filling the Volcengine APP备案 page, deciding domains, answering SDK questions, or choosing 前置审批.

## Safety rules

- Never print or commit `credentials.json`, `.p12`, `.jks`, `.mobileprovision`, keystore passwords, certificate passwords, private keys, or API keys.
- Before finalizing, run `git check-ignore` for downloaded credentials.
- If credentials are unignored, stop and add ignore rules before extracting or sharing outputs.
- Public keys and fingerprints are okay to paste into备案 forms; private keys and passwords are not.
