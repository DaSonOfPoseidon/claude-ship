# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo: a pre-push review gate, git hooks, a hygiene
lint, the `ship` skill with its agents, and a GitHub status that blocks merges until Codex has reviewed. This section says
what each feature does, what triggers it and what it puts in Claude's context. The sections after it are the reference.

## What runs, and when

**Trigger legend**

| Trigger | Meaning |
|---|---|
| **Auto** | Runs on its own on any machine where `./install.sh` ran. No repo setting needed. |
| **Opt-in** | Runs on its own once a setting is on: a repo variable, a repo file or a `settings.json` entry. |
| **Ask** | Runs only when the user says so: a phrase, or a command anyone may run. |
| **User-only** | Claude is blocked from running it. Only the user's `!` command does. |

### A. Install and tamper protection (`install.sh`, `settings/claude-ship.json`)

| Feature | Trigger | Scope |
|---|---|---|
| Deploy `origin/main` into `~/.claude` (hooks, ship agents, skill, shfmt, git-hook stubs) | Ask: the user runs `./install.sh` after each merge | Never deploys a branch |
| Managed-settings drop-in registers the gate (PreToolUse) and two edit hooks (PostToolUse: the lint and the pitfall check) | Auto, after an install as root | Every Claude Code user of the machine; user and project settings can't turn it off. It does **not** register the orchestrate hint hook |
| Global `core.hooksPath` set to `~/.claude/git-hooks` | Auto, when unset | Any other value leaves the pre-push check off, and the gate blocks pushes |
| `chattr +i` on everything installed | Auto, after an install as root | The user lifts it with `! sudo chattr -i <path>` |
| `~/.claude/claude-ship/lint` created once | Auto | The user's file, never overwritten |
| Settings check: prints a missing gate entry, hint hook or `CLAUDE_CODE_FORK_SUBAGENT=0` | Auto, in the install output | Never edits `settings.json` |

### B. Review gate (`hooks/review-gate.sh`, PreToolUse on Bash, Write, Edit, MultiEdit, NotebookEdit and GitHub MCP writes)

**Every repo, every matching tool call (Auto):**

| Check | Effect |
|---|---|
| `jq` missing, or the tool call unreadable | Blocks every call |
| `~/.claude/bin/shfmt` missing, or a Bash command it can't parse | Blocks every Bash call |
| Write or Edit of a protected path (`~/.claude/{hooks,git-hooks,skills/ship,skills/claude-ship,agents/ship-*,bin,claude-ship,settings*}`, `.git/review-gate/`, `/etc/claude-code`), or text that sets `disableAllHooks` | Blocks |
| Bash that writes those paths literally (`cp`, `mv`, `ln`, a redirect, `sed -i`…) | Blocks |
| The review gate's `--waive` or `--prune`, `gh variable set/delete/remove` on `CLAUDE_AUTONOMOUS`, `CLAUDE_ORCHESTRATE` or `CLAUDE_P3_*`, running `codex-allow.sh`, `chattr` | Blocks (these are User-only) |
| `git commit --no-verify` or `-n`, `git push --no-verify`, a write of `core.hooksPath` | Blocks |

**Only in repos where `CLAUDE_AUTONOMOUS` is `true` (Opt-in):**

| Check | Effect |
|---|---|
| A canonical `git push` starts a headless review: a Sonnet finder (P0–P3) and a Haiku verifier; a docs-only change gets a Haiku claims check | Confirmed P0–P2 block; confirmed P3s are kept pending for the branch by `p3-pending.sh` and filed as issues, by `p3-issue.sh`, when the PR is done; a pass is recorded in `.git/review-gate/` |
| Push shape: HEAD's branch to origin only, or one tag whose commit is on the default branch | Anything else blocks |
| `core.hooksPath` must point at the deployed stubs | The push blocks otherwise |
| GitHub MCP write tools (`push_files`, `create_pull_request`, `merge_pull_request`…) | Block |
| `gh api` writes outside the ship skill's allowlist | Block |
| `AGENTS.md` › `## Code Review Rules` must exist | Pushes block until the skill's bootstrap writes it |

The reviewer sessions get the rules and context from the default branch: the Code Review Rules, an optional `### Path rules`
subsection, `docs/pitfalls.md`, `docs/false-positives.md` (both optional), the repo's open P3 issues (so they aren't filed
twice), the branch's pending P3s and the branch diff.

### C. Git hooks (`hooks/git-hook.sh`, run through the `~/.claude/git-hooks` stubs)

| Feature | Trigger | Scope |
|---|---|---|
| Chains to the repo's own `.git/hooks/<name>` (git stops reading it once `core.hooksPath` is set); for Claude's commits and pushes it runs after the lint or the review check passes | Auto | Every repo, everyone's git |
| `pre-push`: refuses a push of a commit with no `.pass` or `.waived` in the review state, however the push started (`gh pr create` included) | Opt-in: the destination repo has `CLAUDE_AUTONOMOUS` `true` | Claude's pushes only |
| `pre-commit`: lints the staged lines and refuses the commit on an error-level hit | Auto | Claude's commits, every repo |
| The user's own pushes and commits | Never checked | A command the user runs with `!` counts as Claude's |

### D. Hygiene lint (`hooks/lint.sh`, `hooks/lint-rules`)

| Feature | Trigger | What enters Claude's context |
|---|---|---|
| PostToolUse `lint.sh hook` after every Write, Edit and MultiEdit | Auto, every repo | An error is `decision: block` feedback ("Fix these now"); a warning is extra context; a clean edit adds nothing |
| The `pre-commit` lint (C above) | Auto | The refusal text in the Bash output |
| Built-in rules (`hooks/lint-rules`) | Auto | |
| Install layer `~/.claude/claude-ship/lint` | Opt-in: edit the file | |
| Repo layer `.github/claude-ship/lint`, read from the default branch | Opt-in: commit the file | |
| `lint.sh staged`, `diff`, `rules`, `check` | Ask: anyone can run them | |

### E. Pitfalls to lint rules (`hooks/pitfall-lint.sh`, `agents/ship-lint-author.md`, `skills/ship/pitfall-lint.md`)

| Feature | Trigger | Scope |
|---|---|---|
| PostToolUse `pitfall-lint.sh hook`: an edit that adds an entry to `docs/pitfalls.md` adds context asking for a background `ship-lint-author` | Opt-in: `CLAUDE_AUTONOMOUS` `true`, Code Review Rules present and the agent installed | Once per session and entry; never blocks |
| `ship-lint-author` agent (Haiku, own worktree, commits, never pushes) | Auto, as the follow-up Claude starts after the hook's advice | The session ships its branch as its own PR |
| Backfill of existing entries | Ask: the bootstrap offers it once | 8 titles per author |
| `pitfall-lint.sh pending` | Ask | CLI |

### F. The `ship` skill (`skills/claude-ship/SKILL.md` and, in `skills/ship/`, its scripts)

| Feature | Trigger | Scope |
|---|---|---|
| The skill's description in the session's skill list | Auto | Listed as `claude-ship`: Claude Code skips a user skill whose directory is named `ship` (it reserves the name for a bundled command), so only `SKILL.md` is deployed apart, to `~/.claude/skills/claude-ship/` ([#350](https://github.com/DaSonOfPoseidon/claude-ship/issues/350)). Everything else stays in `~/.claude/skills/ship/`. Prose here still says "the ship skill" |
| Step 0: check `CLAUDE_AUTONOMOUS` once per session | Auto, when committing or pushing in a GitHub repo | Driven by the skill and that `CLAUDE.md` |
| Commit on its own, then review, push, `@codex review` and triage, at most 3 rounds | Opt-in: `CLAUDE_AUTONOMOUS` `true` | Otherwise Claude asks before committing |
| Codex triage by the outcome table (SKILL.md › Triage): rounds 1–2 fix P0–P2; a P3 is fixed only when the same round fixes a P0–P2, else kept pending until the PR is done (as the gate's are, SKILL.md step 2); round 3 files P2/P3 and asks about P0/P1 | Opt-in, every Codex round | Codex's findings only. The rule lives in the skill, so every opted-in repo gets it |
| The pending P3s (the gate's, and Codex's of rounds 1–2): `p3-pending.sh list` before each commit for the PR (fix the relevant, easy ones in it, never a commit just for them); `p3-pending.sh file <pr>` when the PR is done (step 5), files the rest as issues | Opt-in, every PR | The orchestrator, `worktree-sweep.sh` and the implementer follow the same rule |
| A finding judged not valid: reply and add a `docs/false-positives.md` entry; a new bug class: a `docs/pitfalls.md` entry | Opt-in, every round | |
| Bootstrap (`chore/review-setup`: `AGENTS.md` rules, workflow caller, pitfalls and false-positives files, `review:p3` label) | Opt-in: runs by itself when `AGENTS.md` lacks Code Review Rules | |
| Branch protection requiring `codex-review` | Ask: Claude asks after the bootstrap merges | |
| Codex round 4 and later | User-only: `! ~/.claude/skills/ship/codex-allow.sh <pr> <owner/repo>` | |
| Waive a gate finding | User-only: the gate's `--waive` option, run with `!` (Waivers, `docs/gate.md`) | |
| Prune the gate's old state | User-only: the gate's `--prune` option, run with `!` | |
| P3 labels and milestone (`CLAUDE_P3_LABELS`, `CLAUDE_P3_TYPE_LABEL`, `CLAUDE_P3_MILESTONE`, `.github/claude-ship/p3-labels`) | Opt-in | See Per-repo opt-in, below |
| Filing claude-ship and project bugs unasked (`filing.md`) | Auto, as the skill and the global `CLAUDE.md` instruct | |
| `token-report.sh`, `gate-stats.sh` | Ask | Read-only reports |

### G. Orchestrated PR loop (`skills/ship/orchestrate.md`, `hooks/orchestrate-hint.sh`, `agents/ship-*`)

| Feature | Trigger | What enters Claude's context |
|---|---|---|
| `UserPromptSubmit` hint in plan mode | Opt-in: `CLAUDE_AUTONOMOUS` **and** `CLAUDE_ORCHESTRATE` both `true`, plus the hint hook registered in `settings.json` (it is not in the drop-in) | "Orchestrated mode is on… read `orchestrate.md`…", once per session and repo; with no `## PR loop` section in `AGENTS.md`, also a note that the defaults apply |
| The PR loop without `CLAUDE_ORCHESTRATE` | Ask: "the PR loop", "work the ready issues one PR at a time" | |
| Resume after `/clear` | Ask: "continue the PR loop" | |
| Local loop hint | Opt-in: `- mode: local` in the `## PR loop` section of `AGENTS.md` or `CLAUDE.md` (no variables) | "Local orchestrated mode is on…" |
| Local loop otherwise | Ask: "the local loop" | |
| `## PR loop` settings (checks, ready, skip and priority labels, `merge: yes`, handoff context) | Opt-in, in `AGENTS.md` | Defaults: no merge, `status:ready` |
| Agents: `ship-explorer` (Haiku), `ship-implementer` (Sonnet), `ship-local-implementer`, `ship-codex` (Haiku), `ship-lint-author` | Auto once the loop runs: the orchestrator starts them | `ship-explorer` and `ship-codex` carry frontmatter hooks (`explorer-bash.sh`, `codex-bash.sh`) that restrict their Bash, active only inside those agents |
| `CLAUDE_CODE_FORK_SUBAGENT=0` | Opt-in: the `env` of `settings.json` | Needed for nested agents' reports |

### H. GitHub side (`action.yml`, `.github/workflows/codex-status.yml`, the caller template)

| Feature | Trigger | Runs as |
|---|---|---|
| The `codex-review` commit status (Codex reviewed HEAD and every thread is resolved) | Opt-in: the caller workflow in the repo, which the bootstrap adds | GitHub Actions |
| Merge blocked without it | Opt-in: branch protection | GitHub |
| Fork-PR owner approval comments | Auto, inside the action | GitHub Actions |
| Release by moving `v1` | Ask: Claude may run the three commands; the gate allows one tag push | git |
| Codex "Automatic review" turned off | User sets it in Codex's settings | Codex |

## What gets injected into Claude's context, and when

| When | Source | Content |
|---|---|---|
| Session start | Claude Code itself | The `claude-ship` skill's description (the `ship` skill, see #350) and the `ship-*` agents' descriptions |
| Each prompt in plan mode, once per session and repo | `orchestrate-hint.sh` | The orchestrated or local loop hint |
| Each blocked tool call | `review-gate.sh`, on stderr | Why it blocked, and the findings with their confidence |
| After each Write, Edit and MultiEdit | `lint.sh hook` | Lint hits (block feedback or context) |
| After an edit that adds a pitfall entry | `pitfall-lint.sh hook` | A request to start `ship-lint-author` |
| A refused commit or push | `git-hook.sh`, in the Bash result | `claude-ship: commit refused: …` or the push refusal |
| On demand | Skill files Claude reads | `SKILL.md`, `orchestrate.md`, `filing.md`, `pitfall-lint.md` |

Some work runs in separate processes that add nothing to Claude's context: the gate's headless `claude -p` reviewer sessions,
the git hook processes, GitHub Actions and the subagents. Every reviewer run is logged in `~/.claude/state/review-costs.jsonl`.

## Turning things on

In order; each step needs the one before it.

1. **Install.** Run `./install.sh` as root (Install, below), restart Claude Code and check `/status` for the managed drop-in.
   This alone turns on everything marked Auto. It also protects every repo from Claude's edits to the installed gate and from
   the `--no-verify` and `core.hooksPath` slips.
2. **Opt a repo in.** `! gh variable set CLAUDE_AUTONOMOUS --body true -R <owner/repo>` (Per-repo opt-in, below). From then on
   pushes in that repo are reviewed and Claude commits on its own.
3. **Bootstrap.** While `AGENTS.md` has no `## Code Review Rules`, the gate blocks pushes there; the `ship` skill's bootstrap
   opens a `chore/review-setup` PR with them, the workflow caller and the pitfalls files. Merge that PR before step 4.
4. **Branch protection.** Once the bootstrap PR has merged, require the `codex-review` status on the default branch, so a
   merge waits for Codex. Not earlier: Codex reports a clean review by editing a comment, which runs the default branch's
   workflow (the caller isn't there yet), so the bootstrap PR would never get a passing status and couldn't merge.
5. **Optional**, each on its own:
   - P3 issue labels: `CLAUDE_P3_LABELS`, `CLAUDE_P3_TYPE_LABEL`, `CLAUDE_P3_MILESTONE` and `.github/claude-ship/p3-labels`.
   - Lint tuning: `~/.claude/claude-ship/lint` for this install, `.github/claude-ship/lint` for a repo (Hygiene lint, below).
   - Orchestrated mode: `CLAUDE_ORCHESTRATE`, plus the hint hook in `~/.claude/settings.json` (it isn't in the drop-in).
   - A `## PR loop` section in `AGENTS.md` for the loop's checks, labels and `merge: yes`.
   - `"env": {"CLAUDE_CODE_FORK_SUBAGENT": "0"}` in `~/.claude/settings.json`, for the PR loop.

## Where it lives

- `hooks/review-gate.sh`: a PreToolUse hook that blocks a canonical `git push` until a headless
  review passes (a `git push` that shares its call with other commands is blocked up front when HEAD has no pass; any other push is refused by the pre-push check in `hooks/git-hook.sh`). A Sonnet finder
  reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2 block, and confirmed P3s are kept pending for the
  branch (`hooks/p3-pending.sh`) and filed as issues when the PR is done. Docs-only changes get a Haiku claims check. Prompts are the `hooks/review-*.md` files, built by `hooks/review-lib.sh`. A change to a prompt, model or flag comes with a
  before/after `tests/evals/run.sh` result (seeded-bug cases; it costs tokens, so it runs by hand, not in CI;
  [`docs/gate.md`](docs/gate.md#changing-prompts-or-models)).
- `skills/claude-ship/SKILL.md` and `skills/ship/`: the `ship` skill, listed as `claude-ship` (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `skills/ship/filing.md`: when a session files an issue unasked (a bug in claude-ship's tooling, an agent that didn't
  follow its instructions, a bug in the project outside the task), how, and where. Installed with the skill, so any
  session can read it.
- `skills/ship/orchestrate.md`, `agents/`, `hooks/orchestrate-hint.sh`, `hooks/explorer-bash.sh` and
  `hooks/codex-bash.sh`: the optional orchestrated mode (below).
- `hooks/pitfall-lint.sh`: lists the `docs/pitfalls.md` entries that no lint rule covers, and asks the session for a lint
  author when an edit adds one (Pitfalls and lint rules, below).
- `action.yml` and `scripts/codex-status.sh`: the `codex-review` action. In GitHub Actions it sets the `codex-review` commit
  status that branch protection requires (success once Codex reviewed the PR's head and every Codex thread is
  resolved). Opted-in repos call it through the reusable workflow `.github/workflows/codex-status.yml` from a
  short caller, a copy of `skills/ship/templates/codex-review.yml`. This repo's caller,
  `.github/workflows/codex-review.yml`, is the same except that it calls the local workflow, so a PR here tests
  its own copy.

## Orchestrated mode

For a bigger objective or a queue of ready issues, the main session (Opus) plans and triages, and agents do
the rest, one PR at a time (claude-ship #66):

| Work | Who | Model, effort |
|---|---|---|
| Planning, Codex triage, merge decisions | the main session | Opus, the session's effort |
| Questions about the code, for the plan and the implementer's orientation (its Bash is held to read-only `git` and `gh` by `hooks/explorer-bash.sh`) | `agents/ship-explorer.md` | Haiku, medium |
| Implementing a unit, fixing its gate and Codex findings, opening the PR | `agents/ship-implementer.md` | Sonnet, high; Haiku for trivial units |
| Implementing a unit in local mode (no git, PR, gate or Codex; it never commits) | `agents/ship-local-implementer.md` | Sonnet, high |
| Turning new (or, in a backfill, existing) `docs/pitfalls.md` entries into `warn`-level lint rules with cases, on a local branch in its own worktree that it never pushes (`skills/ship/pitfall-lint.md`) | `agents/ship-lint-author.md` | Haiku, high |
| Running each Codex round for the implementer: request once the pushed head settles (CI runs alongside), wait, wait for CI and read it (a red CI goes back to the implementer, with the failing jobs' log tails, next to the findings), findings, the rule-decided issues and resolves (its Bash and Write are held to the ship scripts and one triage file by `hooks/codex-bash.sh`) | `agents/ship-codex.md` | Haiku, medium |
| The mechanics under it: waiting, listing findings, filing issues | the ship scripts | none |

Progress lives on GitHub (PRs and labels), with the plans kept in `.git/claude-ship/` outside the repo's
files, so the loop keeps going across automatic compaction, and resumes after a `/clear` with "continue the PR
loop". The full process is in `skills/ship/orchestrate.md`. Without a master plan, ready issues are taken by the repo's priority labels (highest first), then oldest first.

It starts by itself in plan mode, in repos where both `CLAUDE_AUTONOMOUS` and `CLAUDE_ORCHESTRATE` are `true`:
the `orchestrate-hint.sh` hook (a `UserPromptSubmit` hook) points Claude to it once per session in each
repo. In other opted-in repos, ask for "the PR loop". The hint hook is not in the managed drop-in (which holds only the gate and the
two edit hooks): register it in `~/.claude/settings.json` (Install, below). The hook adds nothing on any error; it's a convenience,
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

Claude may run this too (it moves the workflow and the action together): the gate lets a push of one tag through, and the
pre-push check accepts it because the tag's commit is already on origin's default branch, as GitHub reports it. Claude runs it
as three commands, since a pushing command may hold only the push (`git fetch origin`, `git tag -f v1 origin/main`, `git push -f origin v1`).
A tag of a commit that isn't on the default branch is refused. The same command creates `v1` the first time. Until
`v1` exists, every caller's `codex-review` run fails to resolve the workflow and sets no status, so create it
right after the PR that added `action.yml` merges, before any repo switches to the action.

Other repos can call the action because claude-ship is public. If it ever goes private, every caller fails to
resolve the action the same way, unless Settings → Actions → General → Access allows them.

## Per-repo opt-in

The push review, the pre-push check, the blocks on GitHub MCP writes and on `gh api` writes outside the ship skill's allowlist, and
autonomous commits apply only where the repo variable `CLAUDE_AUTONOMOUS` is `true`. The gate's tamper protection (protected
paths, `--no-verify`, the user-only commands) and the pre-commit lint apply in every repo, once `./install.sh` has run (the tables
above give each check's scope):

```sh
gh variable set CLAUDE_AUTONOMOUS --body true -R <owner/repo>
gh variable set CLAUDE_P3_LABELS --body "review:p3,<more labels>" -R <owner/repo>   # optional
gh variable set CLAUDE_P3_TYPE_LABEL --body bug -R <owner/repo>                      # optional
gh variable set CLAUDE_P3_MILESTONE --body auto -R <owner/repo>                      # optional
gh variable set CLAUDE_ORCHESTRATE --body true -R <owner/repo>                     # optional, orchestrated mode
```

The gate's confirmed P3s, and Codex's P3s of review rounds 1 and 2 that no commit fixes, are not filed while the PR is open, since
its code isn't live: `hooks/p3-pending.sh` keeps them pending for the branch (in `.git/review-gate/p3-pending/`), Claude fixes the relevant, easy ones in a commit it makes for the PR anyway
(the skill's step 2, the implementer's rule: never a commit just for them), and `p3-pending.sh file <pr>` files what is left
when the PR is done: the skill's step 5, the orchestrator before it merges, or `worktree-sweep.sh` for a branch merged by
hand. A P3 whose code a later commit changed is dropped, and one that is already an issue is skipped. A detached HEAD has no
branch to keep a P3 for, and a push to the default branch has no PR to wait for, so their P3s are filed at once.

P3 issues (the gate's and Codex's once the PR is done, and the Codex findings the skill defers) are filed by `hooks/p3-issue.sh` with
`CLAUDE_P3_LABELS` (default `review:p3`) plus labels by the finding's file, from
`.github/claude-ship/p3-labels` on the default branch. One rule per line, `<glob> <label>[,<label>...]`; every
matching rule adds its labels, except that a matching rule's `area:` label replaces the area of every earlier
rule, so a path gets one area and an override goes after the broad rule (listed before it, the broad rule wins).
`*` spans `/`:

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
share, else none. A P3 on `.github/workflows/codex-review.yml`, when the copy is byte-identical to claude-ship's template
(`skills/ship/templates/codex-review.yml`), is a bug in the template: it is filed in claude-ship instead, with no
milestone and without naming a private repo (`docs/scripts.md` › `hooks/p3-issue.sh`).

The repo then needs `AGENTS.md` › `## Code Review Rules` (the skill's bootstrap writes it). Codex reads the
same section. An optional `### Path rules` subsection of it gives per-path instructions in a fenced block, one
`<glob> <instruction>` per line (`*` spans `/`); an instruction of `skip` leaves the path out of the reviewed diff
(`docs/gate.md` › Path rules):

```
hooks/*        Treat any way a push could pass without review as P0.
*.lock         skip
generated/*    skip
```

## Install

```sh
./install.sh   # deploys origin/main into ~/.claude/hooks, ~/.claude/agents/ship-*.md and ~/.claude/skills/ship (with codex-status.sh) and ~/.claude/skills/claude-ship (the skill's SKILL.md), writes the git hook stubs in ~/.claude/git-hooks, fetches shfmt into ~/.claude/bin, registers the gate in /etc/claude-code/managed-settings.d, removes the hooks and ship agents main has dropped, and sets the immutable flag (chattr +i) on all of it
```

`./install.sh` also sets git's global `core.hooksPath` to `~/.claude/git-hooks` when it is unset (any other value is left
alone and makes the exit non-zero: the gate blocks pushes until it is ours). The stubs there run a pre-push check on
Claude's pushes: a commit with no passing review is refused, however the push started (docs/gate.md › Pre-push check). The
`pre-commit` stub lints Claude's commits too and refuses one that adds an error-level hit (Hygiene lint, below).
Git stops running a repo's own `.git/hooks` once `core.hooksPath` is set, so each stub also runs the repo's hook of the same
name. Your own pushes and commits are untouched, but a command you run with `!` inside Claude Code counts as Claude's: `! git push
--no-verify` and `! git commit --no-verify` skip the checks.

Run `./install.sh` as root, for your own `~/.claude`: if you are root that is just `./install.sh`; otherwise use
`sudo --preserve-env=HOME ./install.sh` (a plain `sudo` may make `$HOME` root's, and the gate would be installed into
root's `~/.claude` while Claude Code runs the one in yours; `CLAUDE_HOME=<dir>` sets the target directly). It registers the
gate in a managed-settings drop-in, `/etc/claude-code/managed-settings.d/claude-ship.json` (a copy of
`settings/claude-ship.json`), which user and project settings can't turn off, and it sets the immutable flag
(`chattr +i`) on everything it installs, the drop-in and `/etc/claude-code` included, so no command Claude runs can change
the installed gate; Claude's own `chattr` calls are blocked. Setting and lifting the flag needs root. To edit an installed
file by hand, lift it first with `! sudo chattr -i <path>` (without `sudo` if you are root; the `!` runs it as you, not as
Claude; `lsattr <path>` shows the flag); the next `./install.sh` lifts and sets the flags itself. Not root: the drop-in
is skipped, the flags can't be set (it warns), and the gate stays registered in user settings only, as below. A failed
shfmt download stops the install before it changes anything.

The drop-in applies to every Claude Code user of the machine, and its hook is `~/.claude/hooks/review-gate.sh` of whoever runs
the session. On a machine with other Claude Code users, run `./install.sh` for each of them first (`CLAUDE_HOME=<their
~/.claude>`), or remove the drop-in (`sudo chattr -i /etc/claude-code /etc/claude-code/managed-settings.d /etc/claude-code/managed-settings.d/claude-ship.json`, then delete the file) and keep the gate in user
settings: a user without the gate installed gets every matching tool call blocked, since the hook is missing and fails closed.
The drop-in also registers two edit hooks for the same users, the hygiene lint's `~/.claude/hooks/lint.sh hook` and the pitfall
hook's `~/.claude/hooks/pitfall-lint.sh hook`; neither has an `onFailure`, so for a user without the install they only show a
non-blocking hook error after each file edit.

After installing, restart Claude Code and check that `/status` lists "Enterprise managed settings (drop-ins)". The
drop-in has the same hook as the snippet below, so while you keep that snippet, Claude Code runs the gate once; once
`/status` shows the drop-in, you can remove the entry from `~/.claude/settings.json`. Until you've seen it there, keep it:
it is the gate if Claude Code doesn't read the drop-in. As root or not, you can always register the hook
in `~/.claude/settings.json`:

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
value that differs); it never edits `settings.json`. A gate registered in the drop-in counts: without the entry above it
reports the drop-in instead of failing.

The hygiene lint also checks each file edit as Claude makes it (Hygiene lint, below), and a second hook asks for a lint rule
when an edit adds an entry to `docs/pitfalls.md` (Pitfalls and lint rules, below). The drop-in has both hooks; in
`~/.claude/settings.json` they are:

```json
{"hooks": {"PostToolUse": [{"matcher": "Write|Edit|MultiEdit", "hooks": [
  {"type": "command", "command": "~/.claude/hooks/lint.sh hook", "timeout": 30},
  {"type": "command", "command": "~/.claude/hooks/pitfall-lint.sh hook", "timeout": 30}
]}]}}
```

They have no `onFailure` on purpose: they run after the write, so they can't undo it, and a failure of their own must never block.
`./install.sh` also creates `~/.claude/claude-ship/lint` (a commented header, no rules) when it is missing, and never
overwrites or locks it; that is the file you edit to tune the lint for this install.

For orchestrated mode, also register the hint hook:

```json
{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/orchestrate-hint.sh"}]}]}}
```

The PR loop (orchestrated mode) keeps `CLAUDE_CODE_FORK_SUBAGENT` set to `"0"` in the settings' `env` (the owner's
decision, claude-ship #160). Under Claude Code's fork mode a subagent's Agent call returns at once; with the setting,
headless sessions get `ship-codex`'s report as the Agent result. In interactive sessions the report reaches the
implementer as a hand-back message, which the implementer acts on (`agents/ship-implementer.md`, step 2). Other users of
the gate don't need the setting.

```json
{"env": {"CLAUDE_CODE_FORK_SUBAGENT": "0"}}
```

`./install.sh` prints an info line when the setting is missing.

`./install.sh` also installs shfmt v3.14.1 into `~/.claude/bin`, checked against a sha256 pinned in the repo
(`scripts/fetch-shfmt.sh`). The review gate reads every Bash command with it and blocks every Bash call, in every
repo, when `~/.claude/bin/shfmt` is missing or can't parse the command (docs/gate.md › Tamper protection), so run
`./install.sh` before relying on a gate that has this check. install.sh fetches shfmt first and, when that fails, stops with exit 1 before it changes anything. It exits non-zero when any other part of the install fails. It needs `curl` and `sha256sum` (or `shasum`); only Linux x86_64 and aarch64 are supported for now.

After a PR merges, run `./install.sh` again to deploy it. The installed files (the ship agents included), the gate's state in
`.git/review-gate/`, the lint config in `~/.claude/claude-ship/` and the settings are protected from Claude's edits (and the gate
denies Claude's `git commit --no-verify` and `-n`, which would skip the pre-commit lint); this repo's source isn't, because
changes to it go through the same review as any other repo. `.git/review-gate/` grows with every review; the user trims it with
`! ~/.claude/hooks/review-gate.sh --prune [--dry-run] [days]` (`docs/gate.md` › Pruning old state).

The matcher sends the MCP tools that write files, branches or PRs (`push_files`, `create_or_update_file`,
`delete_file`, `create_branch`, `create_pull_request`, `update_pull_request`, `update_pull_request_branch`,
`merge_pull_request`) to the gate by tool name, whatever the server is called, and the gate blocks them in
opted-in repos.

The gate reviews HEAD, so it lets a push send only HEAD's branch (or one tag of a commit already on the default branch), to origin, and only when every origin URL is
the same GitHub repo, fetch and push. It reads git config and refs before the command runs, so the push it
reviews may run only the push, an optional leading `cd <dir> &&`, harmless redirects (`2>&1`, `> /dev/null`) and
trailing read-only filters (`tail`, `head`, `cat`, `grep`); a push in any other command (`git commit && git push`, a
script, `bash -c`) is left to the pre-push check, which refuses it unless HEAD's commit passed review.
The push may pass no git global option except `-C <dir>`. In opted-in repos, `gh api` may make only the writes the ship skill uses
(comments, replies, reviews, reactions, issues, labels, workflow runs and its own GraphQL mutations), plus
issue dependency links ("blocked by") and milestones (create, update), which are issue metadata like labels; any other
write, such as commits, refs, PRs, statuses, checks or settings, blocks. It catches Claude's own slips but isn't a security boundary: it matches command text,
and its state is protected by those patterns alone. Branch protection requiring the `codex-review` status is
the server-side backstop. The design notes behind each check are in [`docs/gate.md`](docs/gate.md).

## Hygiene lint

`hooks/lint.sh` checks the lines a diff adds for the slips agents leave behind (conflict markers, invisible
characters, and the rules you write), with a message that says what to do instead. It checks only added lines, so
existing code never fails. The git `pre-commit` stub runs it on every commit Claude makes and refuses the commit on an
error-level hit (below); the commands work from a shell too.

```sh
~/.claude/hooks/lint.sh staged                    # the index against HEAD (against the empty tree before the first commit)
~/.claude/hooks/lint.sh diff origin/main...HEAD   # any range git diff takes
~/.claude/hooks/lint.sh rules src/app.py          # the level of every rule for a path, and the config line that set it
~/.claude/hooks/lint.sh check                     # test the checkout's own rules against their cases and the tree (Testing a rule, below)
~/.claude/hooks/lint.sh staged --only debug-leftover   # report one rule only (--remote: see Claude's commits, below)
```

Each hit prints as `path:line: rule (error|warn): <what to do instead>`, then the line (trimmed to 120 characters) and a
summary. Exit 0 means clean or warnings only, 1 an error-level hit, 2 that it couldn't lint (callers refuse on 2).

**Layers.** A later layer wins, line by line:

1. `hooks/lint-rules`, the built-in defaults (deployed with the hooks and locked; its header is the grammar reference).
2. `~/.claude/claude-ship/lint` (or `$CLAUDE_HOME/claude-ship/lint`), this install's file. `* off` turns the lint off.
3. `.github/claude-ship/lint` in the repository, read with `git show` from the default branch (`origin/HEAD`, else
   `origin/main`, `origin/master`, then `HEAD`; no network call), so a branch can't weaken its own lint. Outside git there is
   no project layer.

**Grammar.** One directive per line; `#` starts a comment at the start of a line. Globs are shell patterns on the
repo-relative path (`*` spans `/`) and can't contain spaces.

```
<rule|*> <off|warn|error> [glob | !glob ...]
ban <id> <level> <glob>[,<glob>...] [comment] '<ERE>' [unless '<ERE>'] -- <message>
skip <glob> ...
```

- A settings line sets a rule's level (`*` is every rule) for the paths its globs match, or every path with no globs. The
  last line that applies to a path wins. A path that matches a `!glob` gets `off` from that line.
- A `ban` line is a rule of your own: a line matching the ERE is a hit unless it also matches the `unless` ERE. Its level
  and globs also work as a settings line for `<id>`, and `ban` lines with one id are one rule with several patterns. Its
  globs may include `!glob` as a settings line's do (`*.sh,!tests/*` is every shell script but the tests). With
  `comment` the EREs match the comment text only. POSIX ERE has no `\b`; write `(^|[^[:alnum:]_])`.
- Globs are shell patterns: `*` (spans `/`), `?` and `[...]`. A backslash makes the next character literal, so
  `skip docs/a\*b.txt` skips the file named `a*b.txt` and nothing else.
- `skip` names paths that are never linted, and adds up across layers. The default list is `*.lock`,
  `package-lock.json`, `*.min.js`, `*.min.css`, `vendor/*`, `node_modules/*` and `*.svg`.
- A malformed line (an unknown level, a `ban` with no ` -- `, an invalid ERE) prints `lint: <file>:<n>: ignored: <why>`
  and is skipped, so a typo doesn't lock every repo.
- Comment text depends on the file's extension and is approximate: `#` for sh, py, rb, yaml, toml and the like, `//` and
  `/* */` lines for the C family, `--` for sql, lua and hs. Other extensions (md included) have no comments.
- Two rules are coded, with a level only: `conflict-marker` (`<<<<<<<` alone or followed by a space, `>>>>>>> ` and
  `||||||| ` at the start of a line, and a bare `=======` only when the file also adds a `<<<<<<<`) and
  `invisible-char` (zero-width and bidi-control characters, and a byte order mark anywhere but the start of the file).

There are no inline disable comments: an exception is a path glob in a config file.

**Testing a rule.** `lint.sh check [--only <rule>]` is for the author of a rule, or CI. It differs from the other modes in
one way: layer 3 is the checkout's own `.github/claude-ship/lint`, not the default branch's. A branch can't weaken the
lint that enforces (`staged`, `diff` and `hook` keep reading the default branch); `check` reads the checkout only to test
a candidate before it is merged.
- **Cases.** Each non-comment line of the checkout's `.github/claude-ship/lint-tests` is `hit <rule> <path> <text>` or
  `miss <rule> <path> <text>`. The fields are separated by single spaces and the text is the rest of the line, literal
  (leading spaces, quotes, a tab and `#` included). The case runs as an added line of `<path>` through the same code a real
  diff goes through, so globs, `unless` and comment detection behave as on a commit; the path need not exist. A `hit`
  passes when the rule reports on the line, a `miss` when it doesn't. Each failure prints as `case FAIL <line>: <case>`,
  with the reason, then `cases: <n> passed, <n> failed`. A case whose path a `skip` line covers can't run and fails.
  The grammar is in the header of `hooks/lint-rules`; this repo's own cases are in `.github/claude-ship/lint-tests`, and
  `tests/lint.sh` runs them.
- **Scan.** Every tracked file of the working tree is then linted as if all its lines were added. The hits print under
  `scan:` as usual, followed by one `scan <rule>: <n> hit(s)` line per rule (`scan: no hits` when there are none). That is
  the false-positive evidence for a new rule: scan hits never fail the check.
- **Exit.** 0 when every case passed. 1 when a case failed, a case line is malformed or names a rule the config doesn't
  define, a config line is malformed (the same `ignored` note on stderr), or `--only` names no defined rule. 2 when it
  couldn't run. `--only` limits the cases and the scan to one rule; `--remote` is not accepted.
- A comment line in `.github/claude-ship/lint` can record which `docs/pitfalls.md` entry a rule came from; the lint
  skips it like any comment (see `hooks/lint-rules`).

**Claude's edits.** A `PostToolUse` hook (`lint.sh hook`, registered in the drop-in and in the Install section's snippet) runs
after every Write, Edit and MultiEdit and reports only the lines that edit wrote, so earlier edits aren't reported again.
It takes them by line number from the edit's result (`tool_response.structuredPatch`, the `+` lines of its hunks, each
checked against the file). A result without line ranges (an older Claude Code, another tool, an unreadable value, a file
that changed since) falls back to matching the new text: a file's lines the diff against `HEAD` adds (the whole file when git
doesn't track it yet, or outside git, where an edit counts the `new_string` lines that `old_string` lacks) that contain the
edit's new text, so then a short new text can match an earlier line that contains it too. An edit that deletes text can expose a
violation anywhere, so it checks every added line. An error-level hit comes
back to Claude as feedback to act on (`"decision": "block"` with the hits and "Fix these now: the pre-commit check refuses
a commit that adds them"; the file is already written), a warning as extra context, and a clean edit prints nothing. It always exits 0: the write has
happened, and a failure of its own becomes a note, never a block. Files git ignores and files under `skip` are not
linted. Reviewer sessions have only Read, Grep and Glob, so the hook never runs in them.

**Claude's commits.** The `pre-commit` stub (`hooks/git-hook.sh`) runs `lint.sh staged --remote` when Claude commits (the
same test as the pre-push check: `CLAUDE_CODE_CHILD_SESSION=1` or a `claude` ancestor). An error-level hit refuses the
commit and lists the hits; warnings print and the commit goes on; the repo's own pre-commit runs after a clean lint. Your
own commits are never linted. Fix the hits; if one is wrong, commit it yourself with `! git commit --no-verify` (the gate
denies Claude's own `--no-verify` and `-n`), or add an exclude (for example `debug-leftover off scripts/*`) to the default branch's
`.github/claude-ship/lint` or to `~/.claude/claude-ship/lint`. `--remote` reads the project file from GitHub's default branch,
not a local ref, so `git remote set-head` or `update-ref` can't point it at the branch; if a GitHub origin can't be read (offline, no
`gh`, a 5xx) it uses the local refs and says so on stderr; a repo with no origin or a non-GitHub origin uses them with no note. During a merge, cherry-pick or revert only
`conflict-marker` is checked, since the other side's code isn't Claude's. A missing or broken `lint.sh` refuses the commit.

**Default rules.** `hooks/lint-rules` ships these (`~/.claude/hooks/lint.sh rules <path>` shows what applies to a path).
Each hit's message says what to do instead.

| Rule | Level | Flags |
|---|---|---|
| `conflict-marker` | error | `<<<<<<<` (with or without a label), `>>>>>>> ` and `||||||| ` at the start of a line (coded rule, see above) |
| `invisible-char` | error | zero-width, bidi-control and mid-file byte-order-mark characters (coded rule) |
| `debug-leftover` | error | js/ts `debugger`; py `breakpoint()`, `pdb.set_trace(`, `import pdb`/`ipdb`; rb `binding.pry`, `binding.irb`, `byebug`; rs `dbg!(`. A line that is only a comment isn't flagged, and neither is a hit in a trailing comment (`breakpoint()  # note` is still a hit) or inside a quoted string. Approximate: the linter counts the quotes before the hit (double quotes only in rs), so an escaped quote or mixed quoting can miscount, a line with a quoted mention and a real statement is exempt, and a comment leader inside a string before a real hit (`"a # b"; breakpoint()`) hides it |
| `placeholder` | error | comments such as `... rest of the code`, `existing code here`/`unchanged`, `TODO implement`, `your code here`, `implementation goes here` |
| `narration` | warn | comments that start with `Added`, `Changed`, `Updated`, `Modified`, `Removed`, `Fixed`, `Moved`, `Renamed`, `Replaced`, `Refactored` or `New:`, or say `as requested` / `per your request` |
| `new-suppression` | warn | `noqa`, `eslint-disable`, `@ts-ignore`, `@ts-nocheck`, `@ts-expect-error`, `type: ignore`, `pyright: ignore`, `shellcheck disable`, `nolint`, `rubocop:disable`, `#[allow(`, `@SuppressWarnings`, `NOSONAR`, `istanbul ignore`, `pragma: no cover`. Off for `*.md`, `*.mdx`, `*.txt`, `*.rst` and `*.adoc` |
| `skipped-test` | warn | js/ts `.skip(`, `.only(`, `.skip.each(`, `.only.each(` (also as a tagged template) on a test declaration (`it`, `test`, `describe`, `context`, `suite`, `specify`, `QUnit`, `Deno`, with modifiers like `test.concurrent.only(`, `QUnit.module.skip(` or `Deno.test.only(`; `cursor.skip(n)` and ava's `t.skip.is(` assertion skip are fine), and a statement of its own that starts with `xit(`, `xdescribe(`, `fdescribe(` or `fit(` and a quoted title (`model = fit(data)` is fine); py `@pytest.mark.skip`, `@unittest.skip`; go `t.Skip(`; rs `#[ignore]`; java/kt `@Disabled`. Conditional skips (`it.skipIf(`, `@pytest.mark.skipif`, `@unittest.skipIf`) are deliberate and aren't flagged. Code files only, so prose that mentions `.only(` is fine |
| `todo-no-issue` | warn | `TODO`, `FIXME`, `XXX` or `HACK` in a comment with no `#123`, link or tracker key right after the marker (`TODO(PROJ-123)`, `TODO PROJ-123`; `UTF-8` in the text is not a key) |
| `new-comment` | off | every added comment except a shebang: turn it on with `new-comment warn` (or `error`) for a no-comments policy |

Tune any of them in your own file, for example `new-suppression off tests/*`, `skipped-test error` or `* off`.

## Pitfalls and lint rules

`docs/pitfalls.md` lists classes of bug past reviews caught; some have a literal signature that the hygiene lint could flag.
`hooks/pitfall-lint.sh` links the two (claude-ship #313). An entry is a line starting `- **` (its bold text is its title) or a `## Title` heading. A file with content but no entry in
either form makes `pending` exit 3 instead of printing an empty queue. The ledger is the `# pitfall: <title> -> <rule-id>[, <rule-id>]` (or `-> none: <reason>`) comment lines of
`.github/claude-ship/lint` (`hooks/lint-rules` has the grammar). An entry is *pending* while no ledger line names its exact
title. The ledger is read from the checkout's file and the default branch's together.

```
~/.claude/hooks/pitfall-lint.sh pending [<dir>]   # the pending titles of <dir>'s repository, one per line
```

A `PostToolUse` hook (`pitfall-lint.sh hook`, registered in the drop-in and in the Install section's snippet) watches every
Write, Edit and MultiEdit. When one changes the toplevel `docs/pitfalls.md` in a repo with a `## Code Review Rules` and
`CLAUDE_AUTONOMOUS` `true`, and an entry in it is pending and absent from `HEAD`'s copy, it adds context that asks the session
to start a background `ship-lint-author` agent (once that agent is installed; until then the hook is silent) for the new entries without stopping its task, and to ship the branch that
agent reports as its own PR afterwards. It asks once per session and entry. An edit of an old entry, of another file, a repo
with no commit or no opt-in, and any error add nothing: the hook only advises and never blocks or writes to the repo.

The agent (`agents/ship-lint-author.md`, Haiku, `isolation: worktree`) and the procedure around it
(`skills/ship/pitfall-lint.md`) are what the advice points to. Given the pitfalls file, the titles and a branch
(`lint/pitfall-<slug>`), the agent decides per entry whether a rule fits: only a literal signature on a single added line that
correct code rarely contains. For those it writes `warn` `ban` lines, at least 2 `hit` and 2 `miss` cases in
`.github/claude-ship/lint-tests`, and the ledger line; the rest get `# pitfall: <title> -> none: <reason>`, which is the usual
answer. It proves each rule with `lint.sh check --only <id>` (3 attempts, then the rule and its cases are dropped), makes one
commit and does not push. The session ships that branch as its own PR after its current task (an orchestrated
`ship-implementer` doesn't start the agent: it reports the titles on a `pitfalls:` line and the orchestrator does). A
**backfill** runs the agent over `pitfall-lint.sh pending` 8 titles at a time, one author after the other on
`lint/pitfall-backfill`, and ships that branch as one PR; the ship skill's bootstrap offers it once for a repo that already has
entries, and it runs only in an opted-in repo or when the user asks.

## Costs

Every reviewer run appends `{date, repo, head, stage, model, effort, rc, cost_usd, findings, confidences}` to
`~/.claude/state/review-costs.jsonl`. `confidences` lists each finding's (or verdict's) 0-100 confidence, `null` where the
reviewer gave none; it is shown with the finding too, and display only: there is no threshold, and nothing about
blocking depends on it.

To measure what a PR cost to build, run `~/.claude/skills/ship/token-report.sh <pr>...` from a checkout of the
repo. It reads that repo's Claude Code transcripts, the cost log above and `gh`, and prints each PR's tokens and
API-price cost by role (main session, then each subagent type, then the gate's reviewers) and model, plus the main
session's peak context. `--since YYYY-MM-DD` adds the repo's PRs created on or after that date, and `--summary` ends
with totals by role and model, the cost per PR and the costliest PRs.

To see whether the gate pays for itself, run `~/.claude/skills/ship/gate-stats.sh <pr>...` (or `--since YYYY-MM-DD`)
from a checkout: per PR and in total, how many Codex findings the gate caught or missed, how often it blocked or was
waived, and what it cost. How it matches them, and its limits, are in [`docs/scripts.md`](docs/scripts.md).
