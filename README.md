# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo:

- `hooks/review-gate.sh`: a PreToolUse hook that blocks `git push` and `gh pr create` until a headless
  review passes. A Sonnet finder reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2
  block, and confirmed P3s are filed as issues. Docs-only changes get a Haiku claims check. Prompts are the
  `hooks/review-*.md` files.
- `skills/ship/`: the `ship` skill (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `skills/ship/orchestrate.md`, `agents/` and `hooks/orchestrate-hint.sh`: the optional orchestrated mode
  (below).
- `action.yml` and `scripts/codex-status.sh`: the `codex-review` action. It sets the `codex-review` commit
  status that branch protection requires (success once Codex reviewed the PR's head and every Codex thread is
  resolved). Every opted-in repo, this one included, calls it from `.github/workflows/codex-review.yml`, a
  copy of `skills/ship/templates/codex-review.yml`.

## Orchestrated mode

For a bigger objective or a queue of ready issues, the main session (Opus) plans and triages, and agents do
the rest, one PR at a time (claude-ship #66):

| Work | Who | Model, effort |
|---|---|---|
| Planning, Codex triage, merge decisions | the main session | Opus, the session's effort |
| Questions about the code, for the plan | `agents/ship-explorer.md` | Haiku, medium |
| Implementing a unit, fixing its gate and Codex findings, opening the PR | `agents/ship-implementer.md` | Sonnet, high; Haiku for trivial units |
| Waiting, listing findings, filing issues | the ship scripts | none |

Progress lives on GitHub (PRs and labels), with the plans kept in `.git/claude-ship/` outside the repo's
files, so the loop resumes after `/clear` with "continue the PR loop". The full process is in
`skills/ship/orchestrate.md`.

It starts by itself in plan mode, in repos where both `CLAUDE_AUTONOMOUS` and `CLAUDE_ORCHESTRATE` are `true`:
the `orchestrate-hint.sh` hook (a `UserPromptSubmit` hook) points Claude to it once per session in each
repo. In other opted-in repos, ask for "the PR loop". The hook adds nothing on any error; it's a convenience,
and the gate still reviews every push.

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
gh variable set CLAUDE_P3_TYPE_LABEL --body bug -R <owner/repo>                      # optional
gh variable set CLAUDE_P3_MILESTONE --body auto -R <owner/repo>                      # optional
gh variable set CLAUDE_ORCHESTRATE --body true -R <owner/repo>                     # optional, orchestrated mode
```

P3 issues (the gate's, and Codex findings the skill defers) are filed by `hooks/p3-issue.sh` with
`CLAUDE_P3_LABELS` (default `review:p3`) plus labels by the finding's file, from
`.github/claude-ship/p3-labels` on the default branch. One rule per line, `<glob> <label>[,<label>...]`; every
matching rule adds its labels, and `*` spans `/`:

```
crates/core/*   area:core
*.md            area:docs,documentation
scripts/*       area:ci
*               status:ready
```

If no label is a type (`bug`, `documentation`, `enhancement`, `type:*`), `CLAUDE_P3_TYPE_LABEL` is added.
Labels the repo doesn't have are skipped. With `CLAUDE_P3_MILESTONE=auto`, the issue goes in the milestone of
the branch's open PR, else of the one milestone its commits' `fixes #N` issues share, else none.

The repo then needs `AGENTS.md` › `## Code Review Rules` (the skill's bootstrap writes it). Codex reads the
same section.

## Install

```sh
./install.sh   # deploys origin/main into ~/.claude/hooks, ~/.claude/agents/ship-*.md and ~/.claude/skills/ship (with codex-status.sh)
```

Register the hook once in `~/.claude/settings.json`:

```json
{"hooks": {"PreToolUse": [{
  "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__.*__(push_files|create_or_update_file|delete_file|create_branch|create_pull_request|update_pull_request|update_pull_request_branch|merge_pull_request)",
  "hooks": [{"type": "command", "command": "~/.claude/hooks/review-gate.sh", "timeout": 1200}]
}]}}
```

For orchestrated mode, also register the hint hook:

```json
{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/orchestrate-hint.sh"}]}]}}
```

After a PR merges, run `./install.sh` again to deploy it. The installed files (the ship agents included), the gate's state in
`.git/review-gate/` and the settings are protected from Claude's edits; this repo's source isn't, because
changes to it go through the same review as any other repo.

The matcher sends the MCP tools that write files, branches or PRs (`push_files`, `create_or_update_file`,
`delete_file`, `create_branch`, `create_pull_request`, `update_pull_request`, `update_pull_request_branch`,
`merge_pull_request`) to the gate by tool name, whatever the server is called, and the gate blocks them in
opted-in repos.

The gate reviews HEAD, so it lets a push send only HEAD's branch, to origin, and only when every origin URL is
the same GitHub repo, fetch and push. It reads git config and refs before the command runs, so a pushing
command may run only git's reads (`status`, `log`, `diff`, `show`, `rev-parse`, `ls-remote`) next to the push,
and may not name a git config file. In opted-in repos, `gh api` may make only the writes the ship skill uses
(comments, replies, reviews, reactions, issues, labels, workflow runs and its own GraphQL mutations), plus
issue dependency links ("blocked by"), which are issue metadata like labels; any other
write, such as commits, refs, PRs, statuses, checks or settings, blocks. It catches Claude's own slips but isn't a security boundary: it matches command text,
and its state is protected by those patterns alone. Branch protection requiring the `codex-review` status is
the server-side backstop.

## Costs

Every reviewer run appends `{date, repo, head, stage, model, cost_usd, findings}` to
`~/.claude/state/review-costs.jsonl`.

To measure what a PR cost to build, run `~/.claude/skills/ship/token-report.sh <pr>...` from a checkout of the
repo. It reads that repo's Claude Code transcripts and `gh`, and prints each PR's tokens and API-price cost by
role (main session, then each subagent type) and model, plus the main session's peak context.
