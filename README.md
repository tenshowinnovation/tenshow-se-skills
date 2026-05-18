# tenshow-se-skills

**北京腾秀创智技术有限公司 (Tenshow Innovation, [tenshowinnovation.com](https://tenshowinnovation.com))** 的软件开发 Agent Skills 仓库。

This repository hosts Tenshow Innovation's internal collection of **Agent Skills** — opinionated, step-by-step workflows that augment AI coding agents (Claude Code, compatible agents) with the company's preferred stack, tooling, and operational defaults for software engineering tasks.

## 什么是 Agent Skill / What is an Agent Skill?

A skill is a directory containing a `SKILL.md` (YAML frontmatter + Markdown instructions) plus optional `references/`, `scripts/`, and `assets/` subdirectories. When the user's request matches a skill's description, the agent loads the skill and follows its workflow.

This repository follows the open **Agent Skills specification**: <https://agentskills.io/specification>

## 仓库结构 / Repository Layout

```text
tenshow-se-skills/
├── README.md                  # this file
└── expo-mobile-dev/           # skill: end-to-end Expo + React Native mobile development
    ├── SKILL.md
    ├── assets/                # scripts & templates referenced by the skill
    └── references/            # deep-dive docs loaded on demand
```

## 当前 Skills / Current Skills

| Skill | 用途 / Purpose |
|---|---|
| [`expo-mobile-dev`](expo-mobile-dev/SKILL.md) | 全流程的 React Native + Expo 移动应用开发：scaffold、装包、装 AI 辅助 skill、按国内外区域配置部署与 OTA。End-to-end Expo mobile development covering scaffolding, opinionated package install (better-auth, TanStack Query/Form, Zustand, sonner-native, zod), AI-development skill provisioning, and region-aware (中国大陆 / international) deployment + OTA strategy. |
| [`marketing-site-dev`](marketing-site-dev/SKILL.md) | 全流程的双语（中/英）公司营销官网开发与火山引擎部署：Astro 6 + React 19 islands + Tailwind 4 构建，TOS + CDN + 免费 DV 证书 + HTTPS/HSTS/HTTP2 一键脚本化部署。Bilingual (zh/en) static marketing site workflow — Astro/React/Tailwind build + Volcengine TOS/CDN/cert/HTTPS-hardening deploy, all scripted via `ve` CLI + Node SDK (with SigV4 escape hatch for actions `ve` doesn't ship). |
| [`expo-app-store-screenshots`](expo-app-store-screenshots/SKILL.md) | App Store 和 Google Play 上架截图的端到端工作流（专注 Expo / React Native 项目）：通过 deep link 驱动 iOS Simulator + Android 设备/模拟器，统一锁定状态栏，多语种 × 多机型批量截屏，再 resize 到商店规格，最后用 Python helper 上传到 App Store Connect / Google Play。End-to-end runbook for App Store / Google Play marketing screenshots for **Expo / React Native** apps — deep-link-driven capture across iOS + Android, clean status bar, per-locale × per-device batch, ImageMagick resize, Python uploaders for both stores. App identity (scheme / bundle ID / package) auto-detected from the project's Expo config; no hardcoding. |

更多 skills 会陆续添加 / More skills will be added over time.

## 如何使用 / Usage

Skills in this repo are designed to be loaded by AI coding agents that implement the agentskills.io specification. Common ways to use them:

1. **Direct copy** — copy a skill directory (e.g. `expo-mobile-dev/`) into your agent's skills folder.
2. **Symlink** — for active development, symlink from the agent's skills folder back into this repo so edits propagate immediately.
3. **Reference in CLAUDE.md** — for Claude Code projects, reference the skill from a project's `CLAUDE.md` so the agent loads it on session start.

The exact installation path varies by agent. Consult your agent's documentation for skill installation.

## 验证 / Validation

Validate any skill in this repo against the spec with [`skills-ref`](https://github.com/agentskills/agentskills/tree/main/skills-ref):

```bash
skills-ref validate ./expo-mobile-dev
```

## Testing / 测试

Two layers of tests live under [`tests/`](tests/README.md):

```bash
pnpm install              # one-time
pnpm test:static          # ~seconds, no LLM cost — run on every change
pnpm test:workflow        # ~10 min, ~$2-5 in tokens — run before shipping
pnpm test                 # both
```

- **Static layer** (`tests/static/`) — `skills-ref` spec validation, markdown lint, link integrity, orphan detection, frontmatter length. Fast, deterministic, CI-friendly.
- **Workflow layer** (`tests/workflow/`) — invokes `claude -p` with each scenario prompt, captures the transcript, and runs assertions to verify the agent actually follows the workflow (right scaffold command, right region-conditional packages, right OTA library, etc.). Three scenarios per skill: international happy path, 中国大陆 happy path, dual-region edge case.

Full docs: [tests/README.md](tests/README.md).

## 贡献 / Contributing

This repository is maintained by 北京腾秀创智技术有限公司. Internal contributors should:

1. Keep each skill's `SKILL.md` under 500 lines — move detail into `references/`.
2. Match `name` in frontmatter to the directory name exactly (lowercase, hyphens only, no consecutive or leading/trailing hyphens — per the spec).
3. Always include `license`, `compatibility`, and `metadata.author/organization/version` in the frontmatter so provenance is clear.
4. When packaging external library workflows into a skill, prefer pointing at the library's official docs over inlining install snippets — those rot quickly.

## License

**MIT** — see [LICENSE](LICENSE).

Copyright (c) 2026 北京腾秀创智技术有限公司 (Tenshow Innovation)
