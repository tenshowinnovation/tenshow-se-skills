#!/usr/bin/env tsx
/**
 * Publish every local skill to ClawHub, under the configured owner handle.
 *
 * Why this exists: `clawhub sync` (the obvious choice) does NOT take an
 * `--owner` flag, so it can only publish to the personal scope of whoever
 * is logged in. Our skills live under the `tenshowinnovation` org, so sync
 * collides with itself ("Slug is already taken: /tenshowinnovation/<slug>").
 *
 * This script does what sync should do, but for org publishing:
 *   1. Find every <repo-root>/<dir>/SKILL.md
 *   2. Parse `name` + `metadata.version` from its YAML frontmatter
 *   3. Ask the registry what version is currently live (via `clawhub inspect`)
 *   4. Decide per skill:
 *        - registry-not-found    → publish (first release)
 *        - local > registry      → publish (new version)
 *        - local == registry     → skip (idempotent — re-running CI is a no-op)
 *        - local  < registry     → error (someone forgot to bump SKILL.md)
 *   5. In --dry-run mode, print the decisions without actually publishing.
 *
 * Usage:
 *   pnpm exec tsx scripts/publish-skills.ts
 *   pnpm exec tsx scripts/publish-skills.ts --dry-run
 *   pnpm exec tsx scripts/publish-skills.ts --changelog "release notes"
 *   pnpm exec tsx scripts/publish-skills.ts --skill marketing-site-dev
 *
 * Requires the `clawhub` CLI on PATH and an active session (either via
 * `clawhub login --token "$CLAWHUB_API_KEY"` first, or whatever the CI step
 * arranges before invoking this script).
 */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { parse as parseYaml } from "yaml";

const REPO_ROOT = process.cwd();
const DEFAULT_OWNER = "tenshowinnovation";

// ─── CLI args ────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);

function takeArg(name: string): string | undefined {
  const i = args.indexOf(name);
  if (i === -1 || i === args.length - 1) return undefined;
  return args[i + 1];
}

const dryRun = args.includes("--dry-run");
const owner = takeArg("--owner") ?? DEFAULT_OWNER;
const skillFilter = takeArg("--skill");
const changelog = takeArg("--changelog") ?? "";
const tagsArg = takeArg("--tags"); // comma-separated; passed through verbatim

// ─── Frontmatter parsing ─────────────────────────────────────────────────────

interface Skill {
  dir: string;
  name: string;
  version: string;
  description: string;
}

function readSkillFrontmatter(skillDir: string): Skill | null {
  const skillMdPath = join(skillDir, "SKILL.md");
  if (!existsSync(skillMdPath)) return null;

  const content = readFileSync(skillMdPath, "utf-8");
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) {
    console.error(
      `✗ ${relative(REPO_ROOT, skillMdPath)}: missing YAML frontmatter`,
    );
    return null;
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = parseYaml(match[1]);
  } catch (e) {
    console.error(
      `✗ ${relative(REPO_ROOT, skillMdPath)}: frontmatter parse error: ${(e as Error).message}`,
    );
    return null;
  }

  const name = String(parsed.name ?? "");
  const metadata = (parsed.metadata as Record<string, unknown>) ?? {};
  const version = String(metadata.version ?? "");
  const description = String(parsed.description ?? "");

  if (!name) {
    console.error(`✗ ${relative(REPO_ROOT, skillMdPath)}: missing \`name\``);
    return null;
  }
  if (!version) {
    console.error(
      `✗ ${relative(REPO_ROOT, skillMdPath)}: missing \`metadata.version\`. ` +
        `This script publishes based on that field — add e.g. \`version: "0.1.0"\` ` +
        `under \`metadata:\`.`,
    );
    return null;
  }
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    console.error(
      `✗ ${relative(REPO_ROOT, skillMdPath)}: \`metadata.version\` "${version}" is not strict semver MAJOR.MINOR.PATCH`,
    );
    return null;
  }

  return { dir: skillDir, name, version, description };
}

function discoverSkills(): Skill[] {
  const out: Skill[] = [];
  for (const entry of readdirSync(REPO_ROOT)) {
    if (entry.startsWith(".") || entry === "node_modules" || entry === "tests" || entry === "scripts")
      continue;
    const full = join(REPO_ROOT, entry);
    try {
      if (!statSync(full).isDirectory()) continue;
    } catch {
      continue;
    }
    const skill = readSkillFrontmatter(full);
    if (!skill) continue;
    if (skillFilter && skill.name !== skillFilter) continue;
    out.push(skill);
  }
  return out;
}

// ─── Semver comparison ───────────────────────────────────────────────────────

/** Compares two strict MAJOR.MINOR.PATCH strings. -1/0/+1. */
function cmpSemver(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

// ─── clawhub CLI calls ───────────────────────────────────────────────────────

function clawhub(args: string[]): { code: number; stdout: string; stderr: string } {
  const r = spawnSync("clawhub", args, { encoding: "utf-8", maxBuffer: 8 * 1024 * 1024 });
  return {
    code: r.status ?? 1,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
  };
}

/** Returns the latest published version for a slug, or null if not on the registry. */
function inspectLatest(slug: string): string | null {
  const r = clawhub(["inspect", slug]);
  const combined = `${r.stdout}\n${r.stderr}`;
  if (/Skill not found or unavailable/i.test(combined)) return null;
  const m = combined.match(/^Latest:\s*(\d+\.\d+\.\d+)/m);
  if (!m) {
    // Skill exists but no Latest line — treat as published-but-no-version,
    // safer to fail loudly than to assume.
    throw new Error(`Could not parse Latest version from clawhub inspect ${slug} output:\n${combined}`);
  }
  return m[1];
}

interface PublishOpts {
  dir: string;
  version: string;
  ownerHandle: string;
  changelog: string;
  tags?: string;
}

function publish(opts: PublishOpts): { code: number; output: string } {
  const cmd = [
    "skill",
    "publish",
    opts.dir,
    "--owner",
    opts.ownerHandle,
    "--version",
    opts.version,
  ];
  if (opts.changelog) cmd.push("--changelog", opts.changelog);
  if (opts.tags) cmd.push("--tags", opts.tags);
  const r = clawhub(cmd);
  return { code: r.code, output: `${r.stdout}\n${r.stderr}`.trim() };
}

// ─── Main ────────────────────────────────────────────────────────────────────

const skills = discoverSkills();
if (skills.length === 0) {
  console.error("✗ No skills found in repo root (expected directories containing SKILL.md).");
  process.exit(1);
}

console.log(`Checking ${skills.length} skill(s) against ClawHub (owner: ${owner})${dryRun ? " [DRY RUN]" : ""}:`);
for (const s of skills) console.log(`  • ${s.name} v${s.version}`);
console.log("");

let published = 0;
let skipped = 0;
let failed = 0;

for (const skill of skills) {
  const local = skill.version;
  let remote: string | null;
  try {
    remote = inspectLatest(skill.name);
  } catch (e) {
    console.error(`✗ ${skill.name}: ${(e as Error).message}`);
    failed++;
    continue;
  }

  let decision: "publish" | "skip" | "regression";
  if (remote == null) decision = "publish";
  else {
    const c = cmpSemver(local, remote);
    if (c > 0) decision = "publish";
    else if (c === 0) decision = "skip";
    else decision = "regression";
  }

  const relDir = relative(REPO_ROOT, skill.dir) || ".";

  if (decision === "skip") {
    console.log(`✓ ${skill.name} — already at v${local} on registry, nothing to do`);
    skipped++;
    continue;
  }

  if (decision === "regression") {
    console.error(
      `✗ ${skill.name} — local v${local} is OLDER than registry v${remote}. ` +
        `Bump \`metadata.version\` in ${relDir}/SKILL.md before publishing.`,
    );
    failed++;
    continue;
  }

  // decision === "publish"
  const action = remote == null ? "first release" : `v${remote} → v${local}`;
  if (dryRun) {
    console.log(`▸ ${skill.name} — would publish (${action})`);
    continue;
  }

  console.log(`▸ ${skill.name} — publishing (${action}) …`);
  const result = publish({
    dir: `./${relDir}`,
    version: local,
    ownerHandle: owner,
    changelog: changelog,
    tags: tagsArg,
  });
  if (result.code === 0) {
    console.log(`✓ ${skill.name}@${local} published`);
    if (result.output) {
      // Forward the CLI's success line (e.g., publish id) for the CI log.
      for (const line of result.output.split("\n")) {
        if (line.trim()) console.log(`    ${line}`);
      }
    }
    published++;
  } else {
    console.error(`✗ ${skill.name}@${local} publish FAILED:`);
    for (const line of result.output.split("\n")) {
      if (line.trim()) console.error(`    ${line}`);
    }
    failed++;
  }
}

console.log("");
console.log("━━━ Summary ━━━");
console.log(`Published: ${published}`);
console.log(`Skipped (already current): ${skipped}`);
console.log(`Failed: ${failed}`);

process.exit(failed > 0 ? 1 : 0);
