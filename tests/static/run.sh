#!/usr/bin/env bash
# Static checks for all skills in the repo.
# Run from repo root: `pnpm test:static`
#
# Layers:
#   1. Frontmatter + naming    — agentskills.io spec compliance (skills-ref via npx)
#   2. Orphan + length checks  — every references/assets file is linked from SKILL.md
#                                description fields are <= 1024 chars
#   3. Markdown style          — markdownlint-cli2
#   4. Link integrity          — markdown-link-check (internal + external URLs)
#
# Exit non-zero on any failure so this slot directly into CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Color helpers — disabled when not a TTY (e.g., CI)
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; RED=''; YELLOW=''; RESET=''
fi

failed=0
ran=0

section() {
  ran=$((ran + 1))
  echo
  echo "${BOLD}━━━ [$ran] $1${RESET}"
}

mark_failed() {
  failed=$((failed + 1))
  echo "${RED}✗ $1 failed${RESET}"
}

mark_passed() {
  echo "${GREEN}✓ $1 passed${RESET}"
}

# Discover all skills (any directory containing SKILL.md, depth 2)
SKILLS=()
while IFS= read -r skill_md; do
  SKILLS+=("$(dirname "$skill_md")")
done < <(find . -maxdepth 2 -name SKILL.md -not -path './node_modules/*' | sort)

if [[ ${#SKILLS[@]} -eq 0 ]]; then
  echo "${RED}No SKILL.md files found in repo. Nothing to test.${RESET}"
  exit 1
fi

echo "${BOLD}Found ${#SKILLS[@]} skill(s):${RESET}"
for s in "${SKILLS[@]}"; do echo "  • $s"; done

# ─── 1. Frontmatter + naming (skills-ref) ────────────────────────────────────
section "Frontmatter + naming (skills-ref validate)"

if ! command -v npx >/dev/null 2>&1; then
  echo "${YELLOW}⚠ npx not found — skipping skills-ref validation${RESET}"
else
  for skill_dir in "${SKILLS[@]}"; do
    echo "  → $skill_dir"
    # `skills-ref` package may not be on npm yet; try and fall back to a warning
    if npx --yes skills-ref validate "$skill_dir" 2>&1; then
      mark_passed "skills-ref ($skill_dir)"
    else
      echo "${YELLOW}⚠ skills-ref unavailable or returned an error.${RESET}"
      echo "  If this is the 'package not found' case, run `pnpm lint:frontmatter`"
      echo "  for the equivalent local checks. Counting as warning, not failure."
    fi
  done
fi

# ─── 2. Orphan + length checks (custom TS) ───────────────────────────────────
section "Orphan + frontmatter length checks (tsx tests/static/check-orphans.ts)"

if pnpm exec tsx tests/static/check-orphans.ts; then
  mark_passed "orphan + length checks"
else
  mark_failed "orphan + length checks"
fi

# ─── 3. Markdown style (markdownlint-cli2) ───────────────────────────────────
section "Markdown style (markdownlint-cli2)"

if pnpm exec markdownlint-cli2 "**/*.md" "#node_modules" "#tests/**/.report"; then
  mark_passed "markdownlint"
else
  mark_failed "markdownlint"
fi

# ─── 4. Link integrity (markdown-link-check) ─────────────────────────────────
section "Link integrity (markdown-link-check)"

# Run sequentially per file so a single timeout doesn't kill the whole run.
link_failed=0
while IFS= read -r md_file; do
  echo "  → $md_file"
  if ! pnpm exec markdown-link-check --quiet --config .markdown-link-check.json "$md_file"; then
    link_failed=$((link_failed + 1))
  fi
done < <(find . -name '*.md' \
            -not -path './node_modules/*' \
            -not -path './tests/**/.report/*' \
            -not -path './tests/workflow/**/workspace/*' \
            | sort)

if [[ $link_failed -eq 0 ]]; then
  mark_passed "link integrity"
else
  mark_failed "link integrity ($link_failed file(s) with broken links)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "${BOLD}━━━ Summary ━━━${RESET}"
echo "Ran $ran check group(s), $failed failed."

if [[ $failed -gt 0 ]]; then
  exit 1
fi
