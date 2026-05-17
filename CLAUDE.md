# Project preferences — `tenshow-se-skills`

Memory for any Claude session working in this repo. Honor these defaults unless the user explicitly overrides in the current turn.

## Git workflow

- **Do NOT auto-commit or auto-push.** Make file changes, surface them to the user, and stop. The user reviews the diff and runs `git add` / `git commit` / `git push` themselves — or explicitly tells Claude to do so for a specific commit.
- The pre-commit hook (`.husky/pre-commit` — markdown-link-check on staged `.md` files) is fine to let run; that's the user's automation, not Claude's.
- The CI workflow (`.github/workflows/ci.yml` — static checks + ClawHub publish) is the user's automation. Claude should not bypass or restructure it without being asked.

## ClawHub publishing

- The CI `publish` job uses `clawhub sync` which lacks an `--owner` flag and so cannot update org-owned skills (`tenshowinnovation/*`). Until that gap is fixed (either by `clawhub` adding the flag, or by replacing `sync` with explicit per-skill `clawhub skill publish --owner tenshowinnovation` loops), **new skills must be published manually**:

  ```bash
  set -a && source .env && set +a
  clawhub skill publish ./<skill-dir> \
    --owner tenshowinnovation \
    --version <semver-from-SKILL.md-metadata.version> \
    --changelog "<short description of what changed>" \
    --clawscan-note "<context for ClawScan about anything that looks unusual>"
  ```

  Claude can run this when the user asks for a publish, but should not run it as a side-effect of other work.
