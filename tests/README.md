# Tests

Two layers of tests for the skills in this repository.

## TL;DR

```bash
pnpm install              # one-time
pnpm test:static          # fast (~seconds), no LLM cost
pnpm test:workflow        # slow (~10 min for 3 scenarios), ~$2-5 in tokens
pnpm test                 # both
```

Static tests are safe to run on every change. Workflow tests should run before shipping a skill edit, not on every save.

---

## Layer 1: Static checks (`tests/static/`)

What it catches:

- Spec violations in `SKILL.md` frontmatter (per https://agentskills.io/specification)
- Orphan files in `references/` or `assets/` that no `SKILL.md` references
- Description field exceeding the 1024-char spec limit
- Broken internal and external links in any markdown file
- Markdown style inconsistencies

What it does NOT catch:

- Whether the agent actually behaves correctly when the skill loads — that's Layer 2.

### Tools

| Tool | Purpose | Where configured |
|---|---|---|
| `skills-ref validate` | Official spec validator from agentskills.io | invoked via `npx` |
| `markdownlint-cli2` | Markdown style | `.markdownlint-cli2.jsonc` |
| `markdown-link-check` | Link integrity (internal + external URLs) | `.markdown-link-check.json` |
| `tsx tests/static/check-orphans.ts` | Orphan detection + frontmatter length + name format | — |

### Running

```bash
pnpm test:static          # all 4 checks
pnpm lint:md              # markdownlint only
pnpm lint:links           # link check only
pnpm lint:frontmatter     # orphan + frontmatter check only
```

Exit code is non-zero on any failure, so CI can gate on it.

### When this layer fails

| Failure | Fix |
|---|---|
| `description is N chars (spec max: 1024)` | Tighten the description in SKILL.md frontmatter |
| `name "X" violates spec` | Rename — lowercase a-z, hyphens only, no leading/trailing/consecutive hyphens |
| `name "X" must match parent directory "Y"` | Rename the directory or the frontmatter to align |
| `orphan — not referenced anywhere in SKILL.md` | Either link the file from SKILL.md or delete it |
| `markdownlint MD0XX` | Fix the style issue, or amend `.markdownlint-cli2.jsonc` if the rule isn't useful |
| `markdown-link-check: 404` | Update the URL; for known-flaky URLs add to the ignore list in `.markdown-link-check.json` |
| `skills-ref unavailable` | Treated as warning (package may not be on npm yet). The orphan + length checks cover the same ground locally. |

---

## Layer 2: Workflow tests (`tests/workflow/`)

What it catches:

- Skill triggers but agent does the wrong thing (wrong scaffold command, skips Step 1 questions, picks wrong region-conditional library, etc.)
- Region-conditional logic — does the agent install `expo-updates` for international and `react-native-update` for China?
- Real ambiguity handling — does the agent commit to one region when the user is dual-region?

What it does NOT catch:

- Whether the produced project actually runs (that's Layer 4 sandbox integration, not built here)
- Subjective quality of phrasing, pacing, explanations

### How it works

1. The runner symlinks each skill from its repo directory into the user's Claude Code skills directory (`~/.claude/skills/` by default, override with `CLAUDE_SKILLS_DIR`).
2. For each scenario in `tests/workflow/<skill-name>/evals.json`, it invokes `claude -p "<prompt>"`, captures stdout, and runs the scenario's assertions against the transcript.
3. Results land in `tests/workflow/<skill-name>/.report/run-<timestamp>.json` (gitignored).
4. Exit code reflects whether every scenario had every assertion pass.

### Scenarios for `expo-mobile-dev`

Three scenarios cover the workflow's main decision tree:

| ID | Prompt sketch | What it tests |
|---|---|---|
| `international` | "Build a fitness tracking app called FitTrail for global users" | International happy path — pinned SDK 55 scaffold, `expo-apple-authentication` + `@react-native-google-signin/google-signin`, `expo-updates` + `eas-update-insights` skill, no WeChat/ICP/Pushy/`react-native-update` |
| `china` | "我要做一个国内的 app，叫腾秀，是公司内部使用的项目管理工具" | China happy path — same scaffold, `expo-apple-authentication` YES but `@react-native-google-signin/google-signin` NO, `react-native-update` + Pushy, ICP 备案, separate `apps/api/`, 火山引擎 (primary) / 阿里云 (fallback) — NOT Cloudflare Workers |
| `dual-region` | "需要做一个 app 同时支持国内和海外用户" | Edge case — does the agent acknowledge dual-region, surface the `APP_REGION` env var pattern, and either explain or ask which to start with? |

### Assertion types

Defined in `evals.json`:

| Type | Behavior |
|---|---|
| `contains` | Substring must appear in transcript (case-sensitive) |
| `contains_ci` | Substring must appear (case-insensitive) |
| `matches` | Regex must match transcript at least once |
| `absent` | Substring must NOT appear |
| `absent_ci` | Substring must NOT appear (case-insensitive) |

### Running

```bash
pnpm test:workflow                                       # all scenarios for all skills
pnpm test:workflow -- --skill expo-mobile-dev            # filter by skill
pnpm test:workflow -- --skill expo-mobile-dev --scenario china   # filter by scenario id
pnpm test:workflow -- --cleanup                          # remove the symlink afterward
```

### Requirements

- **`claude` CLI on PATH** — Claude Code (https://docs.claude.com/claude-code). Override the binary location with `CLAUDE_BIN`.
- **Network access** — invocations talk to Anthropic's API.
- **Time** — ~2-5 min per scenario × number of scenarios.
- **Token budget** — roughly $2-5 per full 3-scenario run on Opus, less on Sonnet.

### When this layer fails

The most common failures and what they usually mean:

| Failure | Likely cause |
|---|---|
| `asks-the-three-step1-questions` fails for both regions | Step 1 of SKILL.md isn't pushy enough; the agent is jumping to scaffolding without confirming name/purpose/region |
| `installs-google-signin-for-international` fails | The agent treated Google sign-in as opt-in instead of default for international — strengthen the wording in Step 3 |
| `skips-google-signin-for-china` fails | The agent ignored the region conditional and added the package anyway — strengthen the "INTERNATIONAL ONLY" warning |
| `uses-react-native-update-not-expo-updates` fails | China OTA conditional broken — review Step 3 OTA section and Step 5 China bullet |
| `mentions-icp-beian` fails | The agent didn't surface ICP 备案 when asked about a China app — strengthen the regulatory checklist in china-deployment.md |
| `no-cloudflare-workers-for-china` fails | The agent recommended CF Workers for China — backend.md needs a more explicit warning, or Step 5 needs to call it out |

When an assertion fails, the runner prints a short excerpt of the transcript showing the mismatch. The full transcript is in the `.report/run-*.json` file for deeper inspection.

### Iterating on a failing scenario

1. Run only that scenario: `pnpm test:workflow -- --scenario <id>`
2. Read the assertion failure + transcript excerpt
3. Decide: is the assertion wrong, or is the skill wrong?
   - **Assertion wrong**: maybe overspecific (regex too tight) or testing the wrong thing. Edit `evals.json`.
   - **Skill wrong**: the workflow needs strengthening. Edit `SKILL.md` or the relevant reference file.
4. Re-run. Repeat until passing.

---

## Adding tests for a new skill

When you add a new skill at `<repo-root>/<new-skill>/`:

1. **Static tests** — they auto-discover any directory with a `SKILL.md`. Run `pnpm test:static` and fix whatever it surfaces (most commonly: orphans, frontmatter issues).
2. **Workflow tests** — create `tests/workflow/<new-skill>/evals.json` following the same shape as `tests/workflow/expo-mobile-dev/evals.json`. Aim for 3-5 scenarios: cover the happy path(s) + one or two ambiguity cases.

The runner auto-discovers any `tests/workflow/<name>/evals.json` whose `<name>` matches a skill directory at the repo root.

---

## CI

Wired via [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Three jobs:

| Job | Triggers | What it does |
|---|---|---|
| `test` | every PR + push to `main` + manual dispatch | Runs `pnpm test:static`. Gates the publish jobs. |
| `publish-preview` | PRs only | `clawhub sync --dry-run` so reviewers see what would publish. |
| `publish` | push to `main` + manual dispatch | `clawhub sync` actual publish. Uses commit message as the per-version changelog; default bump is `patch` (override on manual dispatch). |

**`pnpm test:workflow` is intentionally NOT in CI** — it's slow (~10 min), expensive (~$2-5/run), and non-deterministic. Run it locally before shipping a skill edit. If you want it in CI later, gate on manual dispatch + add `ANTHROPIC_API_KEY` as a repo secret.

### Required repo secrets

- **`CLAWHUB_API_KEY`** — the publish token. Add via **Settings → Secrets and variables → Actions → New repository secret**.

Without this secret, `publish` and `publish-preview` will fail with a clear error message pointing at this section.

---

## Known limitations

- **Workflow tests are non-deterministic**. The same prompt can produce slightly different outputs across runs. Assertions are written to tolerate normal variation, but flakiness is possible. If an assertion is flaky, either relax it (e.g., `matches` with a broader regex) or accept that one failing assertion in a re-run isn't a regression.
- **`skills-ref` may not yet be on npm**. The script falls back to a warning if the package isn't installable. The local orphan + frontmatter checks (`tests/static/check-orphans.ts`) cover the same spec rules.
- **Link checking is rate-limited by external hosts**. Apple Developer portal pages, Chinese app store consoles, and a few others are excluded from link checking entirely (configured in `.markdown-link-check.json`) because they require auth and return 401/403 to any anonymous request.
- **No sandbox integration tests yet** (Layer 4 in the test design). The runner doesn't actually execute `pnpm create expo-app --template default@sdk-55` to verify it succeeds — that would require a clean Docker container and 5-10 min per run. Add later if external tool drift (Expo SDK changes, package install breaks) becomes a recurring source of regressions.
