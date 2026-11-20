# claude-ship

The review → push → Codex process Claude Code follows in every opted-in repo:

- `hooks/review-gate.sh`: a PreToolUse hook that blocks a canonical `git push` until a headless
  review passes (any other push is refused by the pre-push check in `hooks/git-hook.sh`). A Sonnet finder
  reports P0–P3 findings and a Haiku verifier checks them; confirmed P0–P2 block, and confirmed P3s are filed as
  issues. Docs-only changes get a Haiku claims check. Prompts are the `hooks/review-*.md` files, built by `hooks/review-lib.sh`. A change to a prompt, model or flag comes with a
  before/after `tests/evals/run.sh` result (seeded-bug cases; it costs tokens, so it runs by hand, not in CI;
  [`docs/gate.md`](docs/gate.md#changing-prompts-or-models)).
- `skills/ship/`: the `ship` skill (bootstrap a repo, request Codex reviews, triage by the outcome table,
  at most 3 rounds), its helper scripts, and the templates a bootstrap copies into a repo.
- `skills/ship/orchestrate.md`, `agents/`, `hooks/orchestrate-hint.sh`, `hooks/explorer-bash.sh` and
  `hooks/codex-bash.sh`: the optional orchestrated mode (below).
- `action.yml` and `scripts/codex-status.sh`: the `codex-review` action. It sets the `codex-review` commit
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
| Running each Codex round for the implementer: request once the pushed head settles (CI runs alongside), wait, wait for CI and read it (a red CI goes back to the implementer, with the failing jobs' log tails, next to the findings), findings, the rule-decided issues and resolves (its Bash and Write are held to the ship scripts and one triage file by `hooks/codex-bash.sh`) | `agents/ship-codex.md` | Haiku, medium |
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

Claude may run this too (it moves the workflow and the action together): the gate lets a push of one tag through, and the
pre-push check accepts it because the tag's commit is already on origin's default branch, as GitHub reports it. Claude runs it
as three commands, since a pushing command may hold only the push (`git fetch origin`, `git tag -f v1 origin/main`, `git push -f origin v1`).
A tag of a commit that isn't on the default branch is refused. The same command creates `v1` the first time. Until
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
share, else none.

The repo then needs `AGENTS.md` › `## Code Review Rules` (the skill's bootstrap writes it). Codex reads the
same section.

## Install

```sh
./install.sh   # deploys origin/main into ~/.claude/hooks, ~/.claude/agents/ship-*.md and ~/.claude/skills/ship (with codex-status.sh), writes the git hook stubs in ~/.claude/git-hooks, fetches shfmt into ~/.claude/bin, registers the gate in /etc/claude-code/managed-settings.d, removes the hooks and ship agents main has dropped, and sets the immutable flag (chattr +i) on all of it
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
The drop-in also registers the hygiene lint's edit hook, `~/.claude/hooks/lint.sh hook`, for the same users; it has no
`onFailure`, so for a user without the install it only shows a non-blocking hook error after each file edit.

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

The hygiene lint also checks each file edit as Claude makes it (Hygiene lint, below). The drop-in has this hook too; in
`~/.claude/settings.json` it is:

```json
{"hooks": {"PostToolUse": [{"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "~/.claude/hooks/lint.sh hook", "timeout": 30}]}]}}
```

It has no `onFailure` on purpose: it runs after the write, so it can't undo it, and a failure of its own must never block.
`./install.sh` also creates `~/.claude/claude-ship/lint` (a commented header, no rules) when it is missing, and never
overwrites or locks it; that is the file you edit to tune the lint for this install.

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
- `skip` names paths that are never linted, and adds up across layers. The default list is `*.lock`,
  `package-lock.json`, `*.min.js`, `*.min.css`, `vendor/*`, `node_modules/*` and `*.svg`.
- A malformed line (an unknown level, a `ban` with no ` -- `, an invalid ERE) prints `lint: <file>:<n>: ignored: <why>`
  and is skipped, so a typo doesn't lock every repo.
- Comment text depends on the file's extension and is approximate: `#` for sh, py, rb, yaml, toml and the like, `//` and
  `/* */` lines for the C family, `--` for sql, lua and hs. Other extensions (md included) have no comments.
- Two rules are coded, with a level only: `conflict-marker` (`<<<<<<< `, `>>>>>>> ` and `||||||| ` at the start of a
  line, and a bare `=======` only when the file also adds a `<<<<<<<`) and `invisible-char` (zero-width and
  bidi-control characters, and a byte order mark anywhere but the start of the file).

There are no inline disable comments: an exception is a path glob in a config file.

**Claude's edits.** A `PostToolUse` hook (`lint.sh hook`, registered in the drop-in and in the Install section's snippet) runs
after every Write, Edit and MultiEdit and reports only the lines that edit added: a file's lines the diff against `HEAD` adds
(the whole file when git doesn't track it yet, or outside git, where an edit counts the `new_string` lines that `old_string`
lacks), and only those that contain the edit's new text (also when the edit changed just part of a line), so earlier
edits aren't reported again. An edit that deletes text can expose a violation anywhere, so it checks every added line. An error-level hit comes
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
not a local ref, so `git remote set-head` or `update-ref` can't point it at the branch; if GitHub can't be read (offline, no
`gh`, a non-GitHub origin) it uses the local refs and says so on stderr. During a merge, cherry-pick or revert only
`conflict-marker` is checked, since the other side's code isn't Claude's. A missing or broken `lint.sh` refuses the commit.

**Default rules.** `hooks/lint-rules` ships these (`~/.claude/hooks/lint.sh rules <path>` shows what applies to a path).
Each hit's message says what to do instead.

| Rule | Level | Flags |
|---|---|---|
| `conflict-marker` | error | `<<<<<<< `, `>>>>>>> ` and `||||||| ` at the start of a line (coded rule, see above) |
| `invisible-char` | error | zero-width, bidi-control and mid-file byte-order-mark characters (coded rule) |
| `debug-leftover` | error | js/ts `debugger`; py `breakpoint()`, `pdb.set_trace(`, `import pdb`/`ipdb`; rb `binding.pry`, `binding.irb`, `byebug`; rs `dbg!(`. A line that is only a comment isn't flagged, and neither is a hit in a trailing comment (`breakpoint()  # note` is still a hit) or inside a quoted string. Approximate: the linter counts the quotes before the hit (double quotes only in rs), so an escaped quote or mixed quoting can miscount, a line with a quoted mention and a real statement is exempt, and a comment leader inside a string before a real hit (`"a # b"; breakpoint()`) hides it |
| `placeholder` | error | comments such as `... rest of the code`, `existing code here`/`unchanged`, `TODO implement`, `your code here`, `implementation goes here` |
| `narration` | warn | comments that start with `Added`, `Changed`, `Updated`, `Modified`, `Removed`, `Fixed`, `Moved`, `Renamed`, `Replaced`, `Refactored` or `New:`, or say `as requested` / `per your request` |
| `new-suppression` | warn | `noqa`, `eslint-disable`, `@ts-ignore`, `@ts-nocheck`, `@ts-expect-error`, `type: ignore`, `pyright: ignore`, `shellcheck disable`, `nolint`, `rubocop:disable`, `#[allow(`, `@SuppressWarnings`, `NOSONAR`, `istanbul ignore`, `pragma: no cover`. Off for `*.md`, `*.mdx`, `*.txt`, `*.rst` and `*.adoc` |
| `skipped-test` | warn | js/ts `.skip(`, `.only(`, `.skip.each(`, `.only.each(` (also as a tagged template) on a test declaration (`it`, `test`, `describe`, `context`, `suite`, `specify`, with modifiers like `test.concurrent.only(`; `cursor.skip(n)` is fine), `xit(`, `xdescribe(`, `fit(`, `fdescribe(`; py `@pytest.mark.skip`, `@unittest.skip`; go `t.Skip(`; rs `#[ignore]`; java/kt `@Disabled`. Conditional skips (`it.skipIf(`, `@pytest.mark.skipif`, `@unittest.skipIf`) are deliberate and aren't flagged. Code files only, so prose that mentions `.only(` is fine |
| `todo-no-issue` | warn | `TODO`, `FIXME`, `XXX` or `HACK` in a comment with no `#123`, tracker key (`PROJ-123`) or link |
| `new-comment` | off | every added comment except a shebang: turn it on with `new-comment warn` (or `error`) for a no-comments policy |

Tune any of them in your own file, for example `new-suppression off tests/*`, `skipped-test error` or `* off`.

## Costs

Every reviewer run appends `{date, repo, head, stage, model, cost_usd, findings}` to
`~/.claude/state/review-costs.jsonl`.

To measure what a PR cost to build, run `~/.claude/skills/ship/token-report.sh <pr>...` from a checkout of the
repo. It reads that repo's Claude Code transcripts, the cost log above and `gh`, and prints each PR's tokens and
API-price cost by role (main session, then each subagent type, then the gate's reviewers) and model, plus the main
session's peak context. `--since YYYY-MM-DD` adds the repo's PRs created on or after that date, and `--summary` ends
with totals by role and model, the cost per PR and the costliest PRs.

To see whether the gate pays for itself, run `~/.claude/skills/ship/gate-stats.sh <pr>...` (or `--since YYYY-MM-DD`)
from a checkout: per PR and in total, how many Codex findings the gate caught or missed, how often it blocked or was
waived, and what it cost. How it matches them, and its limits, are in [`docs/scripts.md`](docs/scripts.md).
