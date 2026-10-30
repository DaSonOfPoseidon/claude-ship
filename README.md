# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo:

- `hooks/review-gate.sh`: a PreToolUse hook that blocks `git push` and `gh pr create` until a headless
  review passes. A Sonnet finder reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2
  block, and confirmed P3s are filed as issues. Docs-only changes get a Haiku claims check. Prompts are the
  `hooks/review-*.md` files, built by `hooks/review-lib.sh`. A change to a prompt, model or flag comes with a
  before/after `tests/evals/run.sh` result (seeded-bug cases; it costs tokens, so it runs by hand, not in CI;
  [`docs/gate.md`](docs/gate.md#changing-prompts-or-models)).
- `skills/ship/`: the `ship` skill (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `skills/ship/orchestrate.md`, `agents/`, `hooks/orchestrate-hint.sh`, `hooks/explorer-bash.sh` and
  `hooks/codex-bash.sh`: the optional orchestrated mode (below).
- `action.yml` and `scripts/codex-status.sh`: the `codex-review` action. It sets the `codex-review` commit
  status that branch protection requires (success once Codex reviewed the PR's head and every Codex thread is
  resolved). Every opted-in repo, this one included, calls it through the reusable workflow
  `.github/workflows/codex-status.yml` from a short caller, `.github/workflows/codex-review.yml` (a copy of
  `skills/ship/templates/codex-review.yml`).

## Orchestrated mode

For a bigger objective or a queue of ready issues, the main session (Opus) plans and triages, and agents do
the rest, one PR at a time (claude-ship #66):

| Work | Who | Model, effort |
|---|---|---|
| Planning, Codex triage, merge decisions | the main session | Opus, the session's effort |
| Questions about the code, for the plan (its Bash is held to read-only `git` and `gh` by `hooks/explorer-bash.sh`) | `agents/ship-explorer.md` | Haiku, medium |
| Implementing a unit, fixing its gate and Codex findings, opening the PR | `agents/ship-implementer.md` | Sonnet, high; Haiku for trivial units |
| Implementing a unit in local mode (no git, PR, gate or Codex; it never commits) | `agents/ship-local-implementer.md` | Sonnet, high |
| Running each Codex round for the implementer: CI first (a red head goes back to the implementer, with the failing jobs' log tails, before any request), request, wait, findings, the rule-decided issues and resolves (its Bash and Write are held to the ship scripts and one triage file by `hooks/codex-bash.sh`) | `agents/ship-codex.md` | Haiku, medium |
| The mechanics under it: waiting, listing findings, filing issues | the ship scripts | none |

Progress lives on GitHub (PRs and labels), with the plans kept in `.git/claude-ship/` outside the repo's
files, so the loop keeps going across automatic compaction, and resumes after a `/clear` with "continue the PR
loop". The full process is in `skills/ship/orchestrate.md`. Without a master plan, ready issues are taken by the repo's priority labels (highest first), then oldest first.

It starts by itself in plan mode, in repos where both `CLAUDE_AUTONOMOUS` and `CLAUDE_ORCHESTRATE` are `true`:
the `orchestrate-hint.sh` hook (a `UserPromptSubmit` hook) points Claude to it once per session in each
repo. In other opted-in repos, ask for "the PR loop". The hook adds nothing on any error; it's a convenience,
and the gate still reviews every push.

**Local mode** (claude-ship #82) gives a workspace without git or GitHub, such as a local project or data
archive, the same cost model without the PR half: Opus plans, Haiku explores, Sonnet implements, one unit at a
time, and nothing is committed, pushed or reviewed. A unit is done when its checks pass and, if the plan asks
for it, you have checked it by hand. Opt in with `- mode: local` in the `## PR loop` section of the workspace's
`AGENTS.md` or `CLAUDE.md` (no repo variables needed; the hook then points to it in plan mode too), or ask for
"the local loop". Its state is in `~/.claude/state/claude-ship/local/`.

## The codex-review action

Repos call it through a reusable workflow at `@v1`; neither the script nor the workflow body is copied into
them. The caller is short (copy `skills/ship/templates/codex-review.yml`):

```yaml
on:
  pull_request: { types: [opened, synchronize, reopened] }
  pull_request_review: { types: [submitted] }
  issue_comment: { types: [created, edited] }
  workflow_dispatch: { inputs: { pr: { description: Pull request number, required: true } } }
permissions: { contents: read, issues: read, pull-requests: read, statuses: write }
jobs:
  codex-review:
    uses: DaSonOfPoseidon/claude-ship/.github/workflows/codex-status.yml@v1
```

The reusable workflow (`.github/workflows/codex-status.yml`) holds the filter that only Codex's own comments
count, the per-PR concurrency and the action call, so a fix there reaches every repo when `v1` moves. The
triggers and permissions stay in the caller (a called workflow can't exceed its caller's permissions). The
script needs `contents`, `issues` and `pull-requests` read, and `statuses` write. The check run is now named
`codex-review / codex-status`; the `codex-review` commit *status* that branch protection requires is unchanged.
How the script decides, and why a repo's first PR can't get the status, is in
[`docs/scripts.md`](docs/scripts.md).

**Fork PRs.** Codex can't review them (openai/codex#47577) and their `pull_request` run has a read-only token, so
the workflow skips it and a failed review says a retry won't help. The repo owner approves a fork PR's head by
commenting `Okay to merge`, `Approved for merge`, `Ready for prod` or `Owner approved` (the whole comment, any case,
one trailing `.` or `!`) after the head's push. Nobody else's comment counts, a new push needs a new approval, and
unresolved Codex threads still fail it. Same-repo PRs are unaffected.

**Releasing.** Merging to main changes no repo's guard. To release a merged change, move the tag:

```sh
git fetch origin && git tag -f v1 origin/main && git push -f origin v1
```

Claude's gate blocks tag pushes, so the owner runs this (it moves the workflow and the action together). The same command creates `v1` the first time. Until
`v1` exists, every caller's `codex-review` run fails to resolve the workflow and sets no status, so create it
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
Labels the repo doesn't have are skipped. Give every path its triage labels (an area per path, and a `*` rule
for priority and status), because the PR loop only picks up labeled issues. With `CLAUDE_P3_MILESTONE=auto`, the
issue goes in the milestone of the branch's open PR, else of the one milestone its commits' `fixes #N` issues
share, else none.

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
  "hooks": [{"type": "command", "command": "~/.claude/hooks/review-gate.sh", "timeout": 2400, "onFailure": "block"}]
}]}}
```

`onFailure: block` needs Claude Code 2.1.295 or later. Without it, Claude Code lets the call through when the hook
times out, crashes or exits with anything but 0 or 2, so a slow review would push unreviewed code. The `timeout`
must stay above the gate's reviewer budget (2200 s by default, `REVIEW_GATE_BUDGET`); the gate also needs `jq`
and blocks every call without it.

`./install.sh` checks this entry after deploying and prints what to change (the entry above, plus a warning for each
value that differs); it never edits `settings.json`.

For orchestrated mode, also register the hint hook:

```json
{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/orchestrate-hint.sh"}]}]}}
```

The PR loop (orchestrated mode) also needs `CLAUDE_CODE_FORK_SUBAGENT` set to `"0"` in the settings' `env`. Under
Claude Code's fork mode a subagent's Agent call returns at once, so the implementer doesn't get `ship-codex`'s
report as its result (claude-ship #160). Other users of the gate don't need it.

```json
{"env": {"CLAUDE_CODE_FORK_SUBAGENT": "0"}}
```

`./install.sh` prints an info line when the setting is missing.

After a PR merges, run `./install.sh` again to deploy it. The installed files (the ship agents included), the gate's state in
`.git/review-gate/` and the settings are protected from Claude's edits; this repo's source isn't, because
changes to it go through the same review as any other repo.

The matcher sends the MCP tools that write files, branches or PRs (`push_files`, `create_or_update_file`,
`delete_file`, `create_branch`, `create_pull_request`, `update_pull_request`, `update_pull_request_branch`,
`merge_pull_request`) to the gate by tool name, whatever the server is called, and the gate blocks them in
opted-in repos.

The gate reviews HEAD, so it lets a push send only HEAD's branch, to origin, and only when every origin URL is
the same GitHub repo, fetch and push. It reads git config and refs before the command runs, so a pushing
command may run only the push, an optional leading `cd <dir> &&`, harmless redirects (`2>&1`, `> /dev/null`) and
trailing read-only filters (`tail`, `head`, `cat`, `grep`); nothing else runs next to it. The push may pass no git
global option except `-C <dir>`. In opted-in repos, `gh api` may make only the writes the ship skill uses
(comments, replies, reviews, reactions, issues, labels, workflow runs and its own GraphQL mutations), plus
issue dependency links ("blocked by"), which are issue metadata like labels; any other
write, such as commits, refs, PRs, statuses, checks or settings, blocks. It catches Claude's own slips but isn't a security boundary: it matches command text,
and its state is protected by those patterns alone. Branch protection requiring the `codex-review` status is
the server-side backstop. The design notes behind each check are in [`docs/gate.md`](docs/gate.md).

## Costs

Every reviewer run appends `{date, repo, head, stage, model, cost_usd, findings}` to
`~/.claude/state/review-costs.jsonl`.

To measure what a PR cost to build, run `~/.claude/skills/ship/token-report.sh <pr>...` from a checkout of the
repo. It reads that repo's Claude Code transcripts, the cost log above and `gh`, and prints each PR's tokens and
API-price cost by role (main session, then each subagent type, then the gate's reviewers) and model, plus the main
session's peak context.

To see whether the gate pays for itself, run `~/.claude/skills/ship/gate-stats.sh <pr>...` (or `--since YYYY-MM-DD`)
from a checkout: per PR and in total, how many Codex findings the gate caught or missed, how often it blocked or was
waived, and what it cost. How it matches them, and its limits, are in [`docs/scripts.md`](docs/scripts.md).
