#!/usr/bin/env tsx
/**
 * Static checks that don't fit elsewhere:
 *
 *   1. Every file under <skill>/references/ and <skill>/assets/ must be linked
 *      from <skill>/SKILL.md. Orphan files mean either dead content or a
 *      forgotten cross-reference.
 *
 *   2. The `description` field in SKILL.md frontmatter must be <= 1024 chars
 *      (per the agentskills.io spec). Exceeding silently truncates in clients.
 *
 *   3. The `name` field must match the parent directory name exactly, must be
 *      lowercase + hyphens, no consecutive/leading/trailing hyphens.
 *
 * Run from repo root: `pnpm lint:frontmatter` or as part of `pnpm test:static`.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { parse as parseYaml } from "yaml";

const REPO_ROOT = process.cwd();
const SPEC_DESCRIPTION_MAX = 1024;
const SPEC_NAME_MAX = 64;

interface Skill {
  dir: string;
  name: string;
  description: string;
  raw: Record<string, unknown>;
}

const issues: string[] = [];

function fail(msg: string): void {
  issues.push(msg);
}

function readSkillFrontmatter(skillDir: string): Skill | null {
  const skillMdPath = join(skillDir, "SKILL.md");
  if (!existsSync(skillMdPath)) return null;

  const content = readFileSync(skillMdPath, "utf-8");
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) {
    fail(`${skillMdPath}: missing YAML frontmatter (--- ... ---)`);
    return null;
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = parseYaml(match[1]);
  } catch (e) {
    fail(`${skillMdPath}: frontmatter YAML parse error: ${(e as Error).message}`);
    return null;
  }

  return {
    dir: skillDir,
    name: String(parsed.name ?? ""),
    description: String(parsed.description ?? ""),
    raw: parsed,
  };
}

function findSkills(): string[] {
  const skills: string[] = [];
  for (const entry of readdirSync(REPO_ROOT)) {
    if (entry.startsWith(".") || entry === "node_modules" || entry === "tests") continue;
    const full = join(REPO_ROOT, entry);
    try {
      if (statSync(full).isDirectory() && existsSync(join(full, "SKILL.md"))) {
        skills.push(full);
      }
    } catch {
      // skip
    }
  }
  return skills;
}

function checkNameFormat(skill: Skill): void {
  const { name, dir } = skill;
  const dirName = dir.split("/").pop()!;
  const skillMd = relative(REPO_ROOT, join(dir, "SKILL.md"));

  if (!name) {
    fail(`${skillMd}: \`name\` field is missing or empty`);
    return;
  }
  if (name.length > SPEC_NAME_MAX) {
    fail(`${skillMd}: name "${name}" is ${name.length} chars (spec max: ${SPEC_NAME_MAX})`);
  }
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name)) {
    fail(
      `${skillMd}: name "${name}" violates spec — must be lowercase a-z, 0-9, ` +
        `single hyphens; no leading/trailing/consecutive hyphens.`,
    );
  }
  if (name !== dirName) {
    fail(`${skillMd}: name "${name}" must match parent directory "${dirName}"`);
  }
}

function checkDescriptionLength(skill: Skill): void {
  const { description, dir } = skill;
  const skillMd = relative(REPO_ROOT, join(dir, "SKILL.md"));

  if (!description) {
    fail(`${skillMd}: \`description\` field is missing or empty`);
    return;
  }
  if (description.length > SPEC_DESCRIPTION_MAX) {
    fail(
      `${skillMd}: description is ${description.length} chars ` +
        `(spec max: ${SPEC_DESCRIPTION_MAX})`,
    );
  }
}

function walkFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walkFiles(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function checkOrphans(skill: Skill): void {
  const skillMdPath = join(skill.dir, "SKILL.md");
  const skillMdContent = readFileSync(skillMdPath, "utf-8");

  const candidates: string[] = [];
  for (const subdir of ["references", "assets", "scripts"]) {
    candidates.push(...walkFiles(join(skill.dir, subdir)));
  }

  for (const file of candidates) {
    const relFromSkill = relative(skill.dir, file);
    // We accept either a Markdown link `references/foo.md` or just the bare path
    // appearing somewhere in SKILL.md (e.g., inside a code fence).
    if (!skillMdContent.includes(relFromSkill)) {
      fail(
        `${relative(REPO_ROOT, file)}: orphan — not referenced anywhere in ${relative(
          REPO_ROOT,
          skillMdPath,
        )}`,
      );
    }
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

const skills = findSkills();
if (skills.length === 0) {
  console.error("No skills found in repo root.");
  process.exit(1);
}

console.log(`Checking ${skills.length} skill(s):`);
for (const dir of skills) {
  console.log(`  • ${relative(REPO_ROOT, dir)}`);
}

for (const dir of skills) {
  const skill = readSkillFrontmatter(dir);
  if (!skill) continue;

  checkNameFormat(skill);
  checkDescriptionLength(skill);
  checkOrphans(skill);
}

if (issues.length === 0) {
  console.log(`\n✓ All ${skills.length} skill(s) passed orphan + frontmatter checks.`);
  process.exit(0);
} else {
  console.error(`\n✗ ${issues.length} issue(s) found:\n`);
  for (const issue of issues) {
    console.error(`  • ${issue}`);
  }
  process.exit(1);
}
