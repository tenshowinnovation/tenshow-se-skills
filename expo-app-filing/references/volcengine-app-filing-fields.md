# Volcengine APP 备案 Fields

Use this reference when filling the Volcengine APP备案 console for an Expo/EAS app. Confirm the current platform wording in the console, but keep these field meanings.

## APP负责人信息

- Reuse the current order owner when that person is the real app service owner and can complete identity verification.
- Add a new owner when a different company user will handle telecom authority calls, SMS, face verification, and follow-up corrections.

## 备案APP信息

| Field | How to fill |
| --- | --- |
| APP名称 | Use the production display name from the app config and store listing. |
| APP内容 | Pick the closest business category. |
| APP涉及全部域名 | List domains the app itself uses for API, web pages, storage, uploads, callbacks, and public media. |
| 解析在火山引擎的域名 | Select every listed service domain whose DNS is hosted in Volcengine. |

Domain rules:

- Include first-party service domains such as `example.com`, `api.example.com`, and `storage.example.com`.
- Do not include third-party SDK domains for Apple, Alipay, WeChat, analytics, crash reporting, or cloud provider APIs unless the console explicitly asks for third-party SDK service domains.
- Domain registration real-name information must match the filing主体.
- If a domain also serves a website, make sure website ICP filing is handled too.
- Newly registered or transferred domains may need a T+1 wait after real-name verification before filing submission.

## 运营平台信息

Select only platforms that the production app actually ships.

| Platform | Identity field | Certificate fields |
| --- | --- | --- |
| iOS | Bundle ID, for example `com.company.app` | Public key and SHA1 fingerprint from the Apple Distribution certificate. |
| Android | Package name, for example `com.company.app` | Public key and MD5 fingerprint from the release keystore. |

Do not use:

- Expo Go identity
- iOS development certificates
- Android debug keystore
- Simulator-only or one-off local test credentials

Use the EAS-managed distribution certificate and release keystore that will sign production or review builds.

## Feature extraction

After downloading EAS credentials, run:

```bash
/path/to/expo-app-filing/scripts/extract-eas-filing-features.sh /path/to/expo-app
```

Fill:

- iOS `Bundle ID` from the script output or app config.
- iOS `SHA1指纹` from `IOS_SHA1`.
- iOS `公钥` from `IOS_PUBLIC_KEY`.
- Android `包名` from the script output or app config.
- Android `MD5指纹` from `ANDROID_MD5`.
- Android `公钥` from `ANDROID_PUBLIC_KEY`.

If the console accepts only 16进制, remove colons from fingerprints. The script already outputs colon-free uppercase hex for SHA1 and MD5.

## 云资源、IP、语言、SDK

- 云资源 / 选择IP: select the actual Volcengine resources that serve the app backend, storage, CDN, or public IP. If the app is hosted elsewhere, check whether filing should be handled by that access provider.
- APP语言: choose the UI/content languages the production app provides.
- 对外提供SDK服务: choose `否` unless this app ships an SDK for other apps to embed.
- 使用第三方SDK服务: choose `是` if the app includes Apple Sign In, payments, analytics, push, speech SDKs, map SDKs, or similar third-party SDKs.
- 备注: keep short and factual, for example: `本APP提供英语口语练习、AI对话、跟读测评、生词学习和账号登录等功能。`

## 前置审批

Choose `是` only when the actual business involves categories that require pre-approval, such as news, publishing, online culture, broadcasting/film/TV programs, games, religion, finance, drugs/medical devices, ride-hailing, or regulated school tutoring.

For education apps, distinguish general adult/language learning from regulated K12/校外培训. If the product targets school curriculum tutoring or minors in a regulated category, confirm legal/compliance requirements before submitting.

## Common EAS gotchas

- If EAS asks to create `@personal/slug` but the app belongs to an organization, stop and add `expo.owner` before accepting.
- If `eas project:info` says the project is not configured, run `eas init` after owner is correct.
- If `eas credentials` fails because `eas.json` is missing, add a minimal `eas.json` in the Expo app directory.
- If a CLI version constraint blocks commands, either upgrade `eas-cli` or relax the local `eas.json` constraint to the installed version.
