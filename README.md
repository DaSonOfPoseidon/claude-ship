# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo:

- `hooks/review-gate.sh`: a PreToolUse hook that blocks `git push` and `gh pr create` until a headless
  review passes. A Sonnet finder reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2
  block, and confirmed P3s are filed as issues. Docs-only changes get a Haiku claims check. Prompts are the
  `hooks/review-*.md` files.
- `skills/ship/`: the `ship` skill (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `action.yml` and `scripts/codex-status.sh`: the `codex-review` action. It sets the `codex-review` commit
  status that branch protection requires (success once Codex reviewed the PR's head and every Codex thread is
  resolved). Every opted-in repo, this one included, calls it from `.github/workflows/codex-review.yml`, a
  copy of `skills/ship/templates/codex-review.yml`.

## The codex-review action

Repos call it at `@v1`; the script is never copied into them:

```yaml
- uses: DaSonOfPoseidon/claude-ship@v1
  with:
    pr: ${{ github.event.pull_request.number || github.event.issue.number || inputs.pr }}
```

The triggers, the filter that only Codex's own comments count, and the permissions stay in the caller, since
an action can't set them; copy the whole template. The script needs `contents`, `issues` and `pull-requests`
read, and `statuses` write.

**Releasing.** Merging to main changes no repo's guard. To release a merged change, move the tag:

```sh
git fetch origin && git tag -f v1 origin/main && git push -f origin v1
```

Claude's gate blocks tag pushes, so the owner runs this. The same command creates `v1` the first time. Until
`v1` exists, every caller's `codex-review` run fails to resolve the action and sets no status, so create it
right after the PR that added `action.yml` merges, before any repo switches to the action.

Other repos can call the action because claude-ship is public. If it ever goes private, every caller fails to
resolve the action the same way, unless Settings → Actions → General → Access allows them.

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
./install.sh   # deploys origin/main into ~/.claude/hooks and ~/.claude/skills/ship (with codex-status.sh)
```

Register the hook once in `~/.claude/settings.json`:

```json
{"hooks": {"PreToolUse": [{
  "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__.*github.*",
  "hooks": [{"type": "command", "command": "~/.claude/hooks/review-gate.sh", "timeout": 1200}]
}]}}
```

After a PR merges, run `./install.sh` again to deploy it. The installed files, the gate's state in
`.git/review-gate/` and the settings are protected from Claude's edits; this repo's source isn't, because
changes to it go through the same review as any other repo.

The matcher sends every GitHub MCP tool to the gate, which blocks the ones that write files, branches or PRs
(`push_files`, `create_or_update_file`, `delete_file`, `create_branch`, `create_pull_request`,
`update_pull_request`, `update_pull_request_branch`, `merge_pull_request`) in opted-in repos.

The gate reviews HEAD, so it lets a push send only HEAD's branch, to origin, and only when origin fetches from
and pushes to the same GitHub repo. In opted-in repos, `gh api` may make only the writes the ship skill uses
(comments, replies, reviews, reactions, issues, labels, workflow runs and its own GraphQL mutations); any other
write, such as commits, refs, PRs, statuses, checks or settings, blocks. It catches Claude's own slips but isn't a security boundary: it matches command text,
and its state is protected by those patterns alone. Branch protection requiring the `codex-review` status is
the server-side backstop.

## Costs

Every reviewer run appends `{date, repo, head, stage, model, cost_usd, findings}` to
`~/.claude/state/review-costs.jsonl`.
