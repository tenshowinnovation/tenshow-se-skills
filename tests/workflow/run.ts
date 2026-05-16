#!/usr/bin/env tsx
/**
 * Workflow test runner for skills in this repo.
 *
 * For each scenario defined in tests/workflow/<skill-name>/evals.json:
 *   1. Symlink the local skill into the user's Claude Code skills directory
 *      (so `claude -p` will load it) — if not already linked.
 *   2. Invoke `claude -p "<prompt>"` and capture stdout.
 *   3. Evaluate each assertion against the captured transcript.
 *   4. Write a per-run report into tests/workflow/<skill-name>/.report/.
 *   5. Print a summary and exit non-zero if any scenario failed.
 *
 * The symlink is left in place so subsequent runs don't re-link unnecessarily.
 * Use the --cleanup flag to remove it after the run.
 *
 * Usage:
 *   pnpm test:workflow
 *   pnpm test:workflow -- --skill expo-mobile-dev          # filter by skill
 *   pnpm test:workflow -- --scenario international         # filter by scenario id
 *   pnpm test:workflow -- --skill expo-mobile-dev --cleanup
 *
 * Requirements:
 *   - `claude` CLI in PATH (Claude Code)
 *   - Network access for the model invocation
 *   - ~3-10 min per scenario depending on model + scenario complexity
 *   - LLM token budget (~$2-5 per full 3-scenario run on Opus, less on Sonnet)
 */

import { execSync, spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

interface Assertion {
  name: string;
  type: "contains" | "contains_ci" | "matches" | "absent" | "absent_ci";
  value: string;
  rationale: string;
}

interface Scenario {
  id: string;
  title: string;
  prompt: string;
  expected_region: string;
  assertions: Assertion[];
}

interface EvalsFile {
  skill_name: string;
  scenarios: Scenario[];
}

interface AssertionResult {
  name: string;
  type: string;
  passed: boolean;
  rationale: string;
  evidence?: string;
}

interface ScenarioResult {
  id: string;
  title: string;
  prompt: string;
  duration_ms: number;
  transcript_length: number;
  passed: number;
  failed: number;
  assertions: AssertionResult[];
}

// ─── CLI args ────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const skillFilter = takeArg("--skill");
const scenarioFilter = takeArg("--scenario");
const cleanup = args.includes("--cleanup");

function takeArg(name: string): string | undefined {
  const idx = args.indexOf(name);
  if (idx === -1 || idx === args.length - 1) return undefined;
  return args[idx + 1];
}

// ─── Setup ───────────────────────────────────────────────────────────────────

const REPO_ROOT = resolve(__dirname, "..", "..");
const WORKFLOW_ROOT = join(REPO_ROOT, "tests", "workflow");
const CLAUDE_SKILLS_DIR =
  process.env.CLAUDE_SKILLS_DIR ?? join(homedir(), ".claude", "skills");

function which(cmd: string): boolean {
  const r = spawnSync("which", [cmd], { encoding: "utf-8" });
  return r.status === 0;
}

if (!which("claude")) {
  console.error(
    "✗ `claude` CLI not found in PATH.\n" +
      "  Install Claude Code: https://docs.claude.com/claude-code\n" +
      "  Or set CLAUDE_BIN to a custom binary path.",
  );
  process.exit(2);
}

// ─── Skill symlinking ────────────────────────────────────────────────────────

function ensureSymlink(skillName: string, skillSrc: string): {
  linked: boolean;
  target: string;
} {
  mkdirSync(CLAUDE_SKILLS_DIR, { recursive: true });
  const target = join(CLAUDE_SKILLS_DIR, skillName);

  if (existsSync(target)) {
    const stat = lstatSync(target);
    if (stat.isSymbolicLink()) {
      const current = execSync(`readlink "${target}"`).toString().trim();
      if (resolve(CLAUDE_SKILLS_DIR, current) === resolve(skillSrc)) {
        return { linked: false, target };
      }
      console.error(
        `✗ ${target} is a symlink to ${current}, not ${skillSrc}.\n` +
          `  Remove it manually before running tests.`,
      );
      process.exit(3);
    }
    console.error(
      `✗ ${target} exists and is not a symlink — refusing to overwrite.\n` +
        `  If this is a stale install, remove it manually first.`,
    );
    process.exit(3);
  }

  symlinkSync(resolve(skillSrc), target);
  return { linked: true, target };
}

function removeSymlink(target: string): void {
  if (existsSync(target) && lstatSync(target).isSymbolicLink()) {
    unlinkSync(target);
  }
}

// ─── Claude invocation ───────────────────────────────────────────────────────

function runClaudePrompt(prompt: string, timeoutMs = 600_000): {
  stdout: string;
  duration_ms: number;
} {
  const claudeBin = process.env.CLAUDE_BIN ?? "claude";
  const start = Date.now();
  const r = spawnSync(claudeBin, ["-p", prompt, "--output-format", "text"], {
    encoding: "utf-8",
    timeout: timeoutMs,
    maxBuffer: 64 * 1024 * 1024,
  });
  const duration_ms = Date.now() - start;

  if (r.error) {
    console.error(`✗ claude invocation failed: ${r.error.message}`);
    return { stdout: "", duration_ms };
  }
  return { stdout: r.stdout ?? "", duration_ms };
}

// ─── Assertion evaluation ────────────────────────────────────────────────────

function evaluateAssertion(a: Assertion, transcript: string): AssertionResult {
  let passed = false;
  let evidence: string | undefined;

  switch (a.type) {
    case "contains":
      passed = transcript.includes(a.value);
      break;
    case "contains_ci":
      passed = transcript.toLowerCase().includes(a.value.toLowerCase());
      break;
    case "matches": {
      const re = new RegExp(a.value, "i");
      const m = transcript.match(re);
      passed = !!m;
      if (m) evidence = excerpt(transcript, m.index ?? 0, a.value.length);
      break;
    }
    case "absent":
      passed = !transcript.includes(a.value);
      if (!passed) {
        const idx = transcript.indexOf(a.value);
        evidence = excerpt(transcript, idx, a.value.length);
      }
      break;
    case "absent_ci":
      passed = !transcript.toLowerCase().includes(a.value.toLowerCase());
      if (!passed) {
        const idx = transcript.toLowerCase().indexOf(a.value.toLowerCase());
        evidence = excerpt(transcript, idx, a.value.length);
      }
      break;
    default:
      throw new Error(`Unknown assertion type: ${a.type}`);
  }

  return {
    name: a.name,
    type: a.type,
    passed,
    rationale: a.rationale,
    evidence,
  };
}

function excerpt(text: string, idx: number, matchLen: number, ctx = 60): string {
  const start = Math.max(0, idx - ctx);
  const end = Math.min(text.length, idx + matchLen + ctx);
  return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
}

// ─── Scenario execution ─────────────────────────────────────────────────────

function runScenario(s: Scenario): ScenarioResult {
  console.log(`\n  ▸ ${s.id}: ${s.title}`);
  console.log(`    prompt: ${s.prompt.slice(0, 100)}${s.prompt.length > 100 ? "…" : ""}`);

  const { stdout, duration_ms } = runClaudePrompt(s.prompt);

  const results = s.assertions.map((a) => evaluateAssertion(a, stdout));
  const passed = results.filter((r) => r.passed).length;
  const failed = results.length - passed;

  console.log(
    `    ${failed === 0 ? "✓" : "✗"} ${passed}/${results.length} assertions passed ` +
      `(${(duration_ms / 1000).toFixed(1)}s, ${stdout.length} chars)`,
  );
  for (const r of results) {
    if (!r.passed) {
      console.log(`      ✗ ${r.name} — ${r.rationale}`);
      if (r.evidence) console.log(`         evidence: ${r.evidence}`);
    }
  }

  return {
    id: s.id,
    title: s.title,
    prompt: s.prompt,
    duration_ms,
    transcript_length: stdout.length,
    passed,
    failed,
    assertions: results,
  };
}

// ─── Skill iteration ─────────────────────────────────────────────────────────

interface SkillJob {
  name: string;
  src: string;
  evalsPath: string;
}

function discoverSkillJobs(): SkillJob[] {
  const jobs: SkillJob[] = [];
  if (!existsSync(WORKFLOW_ROOT)) return jobs;
  for (const entry of readdirSync(WORKFLOW_ROOT)) {
    const evalsPath = join(WORKFLOW_ROOT, entry, "evals.json");
    const src = join(REPO_ROOT, entry);
    if (existsSync(evalsPath) && existsSync(src)) {
      if (skillFilter && entry !== skillFilter) continue;
      jobs.push({ name: entry, src, evalsPath });
    }
  }
  return jobs;
}

// ─── Main ────────────────────────────────────────────────────────────────────

const jobs = discoverSkillJobs();
if (jobs.length === 0) {
  console.error("No workflow test suites found under tests/workflow/.");
  console.error("Expected: tests/workflow/<skill-name>/evals.json");
  process.exit(1);
}

console.log(`Running workflow tests for ${jobs.length} skill(s):`);
for (const j of jobs) console.log(`  • ${j.name}`);
console.log(`Skills directory: ${CLAUDE_SKILLS_DIR}`);

let totalScenarios = 0;
let totalPassed = 0;
let totalAssertionsPassed = 0;
let totalAssertionsRun = 0;

for (const job of jobs) {
  console.log(`\n━━━ ${job.name} ━━━`);
  const link = ensureSymlink(job.name, job.src);
  if (link.linked) {
    console.log(`✓ symlinked ${job.src} → ${link.target}`);
  } else {
    console.log(`✓ symlink already in place at ${link.target}`);
  }

  let evals: EvalsFile;
  try {
    evals = JSON.parse(readFileSync(job.evalsPath, "utf-8"));
  } catch (e) {
    console.error(`✗ failed to parse ${job.evalsPath}: ${(e as Error).message}`);
    if (cleanup) removeSymlink(link.target);
    continue;
  }

  const scenarios = scenarioFilter
    ? evals.scenarios.filter((s) => s.id === scenarioFilter)
    : evals.scenarios;

  if (scenarios.length === 0) {
    console.error(`✗ no scenarios matched filter --scenario ${scenarioFilter}`);
    if (cleanup) removeSymlink(link.target);
    continue;
  }

  const results: ScenarioResult[] = [];
  for (const s of scenarios) {
    results.push(runScenario(s));
  }

  totalScenarios += results.length;
  totalPassed += results.filter((r) => r.failed === 0).length;
  totalAssertionsPassed += results.reduce((sum, r) => sum + r.passed, 0);
  totalAssertionsRun += results.reduce((sum, r) => sum + r.passed + r.failed, 0);

  const reportDir = join(WORKFLOW_ROOT, job.name, ".report");
  mkdirSync(reportDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const reportPath = join(reportDir, `run-${stamp}.json`);
  writeFileSync(
    reportPath,
    JSON.stringify(
      {
        skill: job.name,
        timestamp: new Date().toISOString(),
        skills_dir: CLAUDE_SKILLS_DIR,
        scenarios: results,
      },
      null,
      2,
    ),
  );
  console.log(`\n  📊 Report: ${reportPath}`);

  if (cleanup) {
    removeSymlink(link.target);
    console.log(`✓ removed symlink at ${link.target}`);
  }
}

console.log(
  `\n━━━ Summary ━━━\n` +
    `Scenarios: ${totalPassed}/${totalScenarios} passed (every assertion passing).\n` +
    `Assertions: ${totalAssertionsPassed}/${totalAssertionsRun} passed.`,
);

process.exit(totalPassed === totalScenarios ? 0 : 1);
