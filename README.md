# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo:

- `hooks/review-gate.sh`: a PreToolUse hook that blocks `git push` and `gh pr create` until a headless
  review passes. A Sonnet finder reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2
  block, and confirmed P3s are filed as issues. Docs-only changes get a Haiku claims check. Prompts are the
  `hooks/review-*.md` files.
- `skills/ship/`: the `ship` skill (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `scripts/codex-status.sh` and `.github/workflows/codex-review.yml`: this repo's own Codex sign-off. The
  master copies for other repos are in `skills/ship/templates/`.

## Per-repo opt-in

The gate and autonomous commits apply only where the repo variable `CLAUDE_AUTONOMOUS` is `true`:

```sh
gh variable set CLAUDE_AUTONOMOUS --body true -R <owner/repo>
gh variable set CLAUDE_P3_LABELS --body "review:p3,<more labels>" -R <owner/repo>   # optional
```

The repo then needs `AGENTS.md` › `## Code Review Rules` (the skill's bootstrap writes it). Codex reads the
same section.

## Install

```sh
./install.sh   # deploys origin/main into ~/.claude/hooks and ~/.claude/skills/ship
```

Register the hook once in `~/.claude/settings.json`:

```json
{"hooks": {"PreToolUse": [{
  "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__github__push_files|mcp__github__create_or_update_file|mcp__github__create_pull_request|mcp__github__update_pull_request_branch",
  "hooks": [{"type": "command", "command": "~/.claude/hooks/review-gate.sh", "timeout": 1200}]
}]}}
```

After a PR merges, run `./install.sh` again to deploy it. The installed files, the gate's state in
`.git/review-gate/` and the settings are protected from Claude's edits; this repo's source isn't, because
changes to it go through the same review as any other repo.

## Costs

Every reviewer run appends `{date, repo, head, stage, model, cost_usd, findings}` to
`~/.claude/state/review-costs.jsonl`.
