# The helper scripts: design notes

Each script keeps a short header (what it does, its arguments and exit codes) and brief comments on its checks;
the reasons behind them are here. The gate's notes are in [`gate.md`](gate.md), classes of bug past reviews
caught are in [`pitfalls.md`](pitfalls.md), and the label map and variables `p3-issue.sh` reads are in the
[README](../README.md#per-repo-opt-in).

## `scripts/codex-status.sh`

The only copy of the status script. Repos run it through this repo's action (`action.yml`, called at `@v1`), and
`install.sh` deploys it into the ship skill for local checks. `DRY_RUN=1` prints the status instead of setting
it; `HEAD_SHA` checks another commit, to test against past reviews.

| State | When |
|---|---|
| `success` | Codex completed a review of the head commit after it was pushed, and every Codex review thread is resolved |
| `failure` | a Codex thread is unresolved, or Codex's review failed |
| `pending` | no completed review of the head yet, or the review stalled or can't be tied to a request |

Resolve a thread once its finding is fixed, or answered with why it doesn't apply.

**Push time.** Codex's summary names commits by a 7-character SHA, which someone could forge a collision for, so
a review counts only if it finished after the head was last pushed. The push time comes from GitHub's own
activity records for the branch (`push`, `force_push`, and `branch_creation` for a new branch's first push).

**The summary.** Codex keeps one summary comment per PR and edits it as reviews run. Its Code Review row names
the commit it reviewed and the status. A hidden `codex-review-state:v1` JSON marker in it says whether a review
is running.

**Rows that name no commit.** A clean review's row can show `—` instead of a commit (#30). Nothing ties that
completion to a request: neither the summary's edit history nor Codex's reactions say which request it answers.
A new request ends any review still running on the PR (#61: in all 14 overlaps across three repos, only one
completion followed), so only the latest trusted request counts. It must have come after the push, and exactly
one completion marker, the current one included, must follow it:

- none means the review is still running;
- more than one means a completion nobody asked for (an automatic review, #49), so the status fails closed with
  `pending` and says to ask again;
- a marker in the same second as the request counts as before it (times compare as text, to the second).

Anyone can comment `@codex review`, so only the owner and collaborators count as trusted (an org member needn't
have access to this repository). Earlier completions leave a marker: a receipt comment starting
`<!-- codex-review-receipt:v1 -->` for a clean review (a few seconds before Codex edits the summary; seen on
OBDCracker #145 and #28 here), or a pull request review when it had findings.

**Stalls.** Codex sometimes leaves a review running forever: the 👀 stays on the request, the summary says
running and is never edited again (openai/codex#55890, #61). After `CODEX_STALL_SECS` (default 900) with no
summary edit, no trusted request and no push, the status stays `pending` but says so, so the review can be
asked for again. A retry Codex hasn't picked up yet isn't a stall, and neither is a state that names another
commit or that isn't JSON.

**Errors.** Each GitHub call is its own assignment, so `set -e` stops on a failed call; reading a pipeline's last
exit status would turn an empty result into "no findings".

## `skills/ship/codex-round.sh`

Counts the `@codex review` comments a PR has used, the way `codex-status.sh` counts requests: not from a bot, from
the owner or a collaborator, and `@codex review` as a word. A request whose review stalled doesn't count: Codex's
own 👀 is still on it after `CODEX_STALL_SECS`. Codex removes its 👀 when a review finishes (on #61's survey of
three repos, all 125 finished requests had lost it and all 14 stalled ones kept it), and anyone can react, so only
the bot's own 👀 marks a stall. A review still running past 15 minutes is left out only until it finishes; the
skill counts rounds when it requests the next, after the last has finished or stalled.

## `skills/ship/codex-triage.sh`

Applies a round's triage in one call, so the orchestrator spends one turn on it instead of one per reply, issue
and resolve (each turn re-reads its whole context, #71). It is run by whoever triages: in orchestrated mode the
orchestrator, since subagents can't resolve threads (#100), from the checkout `p3-issue.sh` should read.

- **Input** is a JSON array written with the Write tool, so reply text never passes through shell quoting. Each
  entry has `thread`, `outcome` (`not-valid`, `issue` or `fixed`), `reply`, and `issue` (`file`, `title`, `body`)
  exactly when the outcome is `issue`. The whole file is validated first: any invalid entry, or an empty array
  (a caller bug), exits 2 before any call.
- **Per entry**, in order: for `issue`, `p3-issue.sh` files it (found next to `hooks/`, else
  `~/.claude/hooks/`) and its URL is appended to the reply; then the reply (`addPullRequestReviewThreadReply`),
  then `resolveReviewThread`. Both are on the gate's mutation allowlist. The reply goes in as a `-f` variable,
  never in the query text and never `-F` (which reads a value starting with `@` as a file), so quoted Codex
  text can't alter the mutation.
- **A `fixed` entry** replies and resolves too. In orchestrated mode the implementer has already replied on the
  threads it fixed, so the orchestrator resolves those itself and leaves them out of the file.
- **Stops at the first failed call**, printing `done:` (the threads finished) and `failed:` (the thread and
  step) to stderr, exit 1. A failed reply may have posted and a failed resolve leaves a posted reply, so check
  the thread before rerunning with the finished threads removed from the file.
- **Ends with the status recheck** (`gh workflow run codex-review.yml`) only when no entry is `fixed`: a fix
  means a push and a new request, which recheck it anyway.

## `skills/ship/codex-wait.sh`

Runs `codex-status.sh` with `DRY_RUN=1` every 60 seconds. A status that only a new request clears (stalled, or
finished more than once) ends the wait with exit 3, so it isn't read as "not done yet" until the cap. Any failure
of the status script ends the wait with its error.

## `skills/ship/token-report.sh`

Reads only this repo's transcripts, keeps no state and calls no model.

**Attribution.** A main-session request belongs to the PR whose window holds its timestamp. A PR's own window
runs from the earlier of its creation and its first commit, to the merge, else to the close of a PR closed
unmerged, else to now (open). A closed PR must not run to now, or it would swallow every later request.
The window then widens at the start (#80), because most of a PR's main-session work (planning, exploring,
implementing) comes before its first commit: the start moves back to the later of the end of the author's
previous PR (the latest merge or close before this PR's own start, among their other PRs from one
`gh pr list --author`, newest 200) and the first request of the main transcripts that have a request in the PR's
own window, and never to after its own start. The report shows the widened start. Work after the last merge
isn't printed. A request inside some PR's own window goes to the latest-started of those; only a request in none
goes to the latest-started widened window, so widening never takes work from an overlapping PR. All this is done
across every PR that could matter, not just the PRs asked for: the asked ones plus the author's other PRs that end
at or after the earliest previous-PR end (each read with `gh pr view`, since the list has no commit dates), all with
the same window rules. Only the asked PRs' rows are printed, and a request won by another PR is dropped, so a PR's
row is the same whichever other PRs are asked for (`tests/token-report.sh` checks this directly). A failed or odd
`gh pr list`, or a PR with no author (a deleted account), is an error: reading it as "no earlier PRs" would reach
the window back to the session's start. A whole subagent transcript belongs to the PR whose window holds its last
request: implementers start before their first commit but end after a push or a fix round. Anything else isn't
printed. A session started in a worktree logs under that directory's own slug, so neither it nor its subagents
are counted.

**Prices.** USD per MTok, from the claude-api skill's `shared/models.md` (cached 2026-10-06). `w5` and `w1` are
the 5-minute and 1-hour cache writes; `big` replaces `std` when a request's prompt (input + cache read + cache
write) is over 100k tokens. Issue #70 says Sonnet cache reads cost $0.10; the skill docs say $0.20.

**Records.** A request spans several transcript lines, so the one with the most output is kept. Cache writes use
the 5m/1h split, with any remainder of the total priced as 5m. Costs are integer nano-dollars (tokens x $/MTok x
1000), so rounding to the cent is exact. Times are cut to `YYYY-MM-DDTHH:MM:SS` (transcripts carry milliseconds)
and compared as text.

## `hooks/p3-issue.sh`

Files a finding as an issue. The finding goes in a JSON file rather than on the command line because the gate
reads a command naming `~/.claude/hooks` with a `>` anywhere in it as a write.

- **Labels** come from `CLAUDE_P3_LABELS`, plus every rule in `.github/claude-ship/p3-labels` that matches the
  finding's file, read from the default branch (a branch can't change how its own findings are filed). Labels the
  repo doesn't have are dropped, and one that differs from a repo label only in case is filed under the repo's
  spelling. The type fallback goes by the labels that will actually be applied.
- **Milestone**, only with `CLAUDE_P3_MILESTONE=auto`: the branch's open PR's, else the one milestone of the
  issues its commit subjects fix (`fixes #N`), else none.
- **Never lost to its labels.** If filing fails, it retries without the milestone, then without labels.

## `hooks/orchestrate-hint.sh`

A convenience, not a protection: on any error it adds nothing and lets the prompt through. It looks the repo
variables up only until it has an answer once per session and repo (claude-ship #66). A variable that isn't set
is an answer. A lookup that fails otherwise (network, rate limit) isn't: it adds nothing, writes no mark, and the
next prompt asks again (claude-ship #67).

## `hooks/explorer-bash.sh`

A PreToolUse hook in `agents/ship-explorer.md`'s frontmatter (claude-ship #68). The explorer reads issue and PR
text, which can steer it, and had a free shell with only prose asking it to stay read-only. Claude Code runs a
subagent's frontmatter hooks only while that subagent runs, and exit 2 denies the call and shows the agent the
stderr. They are ignored for plugin subagents and, for a project's agents, until the workspace is trusted; the
installed agent is a user agent. The frontmatter names the installed path, `install.sh` deploys the script
there, and no `settings.json` entry is needed.

- **An allowlist of characters, then of commands.** The command may hold only letters, digits, space and
  `_./:=,@%+^~-`. With no quote, escape, `$`, backtick, redirect, list separator, glob or brace character,
  the words the hook checks are the words that run (`--out''put`, `--out{put,}` and `\--output` can't hide an
  option). Some harmless quoted forms (`--grep="a b"`) are refused as a result. The first word must then be
  `git` or `gh` with a listed subcommand directly after it, so `git -c` / `-C` / `--git-dir` never get a say.
- **Options that write or run something.** git: `--output`, `--ext-diff`, `--textconv`, `--no-index`,
  `--open-files-in-pager`, and `-o` / `-O`. git accepts any unambiguous abbreviation of a long option and bundled
  short options (`-nO`), so a long option denies when it abbreviates or extends one of these, and a short cluster
  denies when it holds `o` or `O` (so `-Sfoo` is refused too). Every word is checked, including those after a
  `--`, which can be an option's argument rather than the end of options (`git grep -e -- --open-files-in-pager=x`),
  so a pathspec that looks like one of these is refused. gh: `-f`, `-F`, `--field`, `--raw-field`, `-X`,
  `--method`, `--input` (the short ones also bundled: `-XPOST`) and any `mutation`, in any case; `--web` / `-w`
  for `view` and `diff`. gh's long options can't be abbreviated, so those match exactly.
- **Left out.** `ls`, `cat`, `wc`, `head`, `tail`: the explorer has Read, Grep and Glob, and the prose never
  listed them. A denied call tells the agent what is allowed.
- **Fails closed.** Input that isn't JSON, has no string `tool_input.command`, or is empty denies. It does not
  stop `git diff` using a `diff.external` driver from the repo's own config, which a branch can't set. Like the
  gate, it is for Claude's slips and steering, not a security boundary.

## `install.sh`

Only `origin/main` is deployed, so what runs has passed review. That holds for the installer too: after
fetching, it runs main's copy of itself, so a checkout behind main still deploys what main's installer knows to
(#20). The gate's hook entry lives in `~/.claude/settings.json` (see the README).

## `action.yml` and the workflows

The status script is the action's own copy, at the ref the caller names (`@v1`, a tag moved on release), so
nothing in the calling repo, including a PR's changes, decides it. The bot-only filter, the per-PR concurrency
and the action call live in the reusable workflow `.github/workflows/codex-status.yml`, which callers reference
at the same `@v1`, so one fix reaches every repo when the tag moves (before, each repo carried a 46-line copy
that went stale). Triggers and permissions stay in the short caller (`skills/ship/templates/codex-review.yml`),
since a called workflow can't set triggers or exceed its caller's permissions. This repo's own caller uses the
local path (`./.github/workflows/codex-status.yml`), so a PR exercises the new file before `v1` moves.

Inside a called workflow `github.event` is the caller's event, so the PR number expressions work as before. The
`inputs` context there is the workflow's own `workflow_call` inputs, not the caller's dispatch inputs, so a
dispatch run's number is read from `github.event.inputs.pr`. The action step stays `@v1` rather than `./`: a
called workflow has no checkout of claude-ship, and `./` would mean the caller's repo. A dispatch run uses the
default branch's caller, so that path can only be checked after a change merges.

The check run is named `codex-review / codex-status` (caller job / called job). The required `codex-review`
commit *status* the script sets is unchanged, and it is what branch protection reads.

`v1` moves (owner only) when claude-ship releases, which changes the check in every caller without a PR there. A
PR that changes the ref needs write access; fork PRs get a read-only token, which can't set statuses.

A repo's first PR (the one that adds the workflow) can't rely on the status: Codex reports a clean review by
editing a comment, which runs the default branch's workflow, and that branch doesn't have it yet. Require
`codex-review` in branch protection only after that PR merges, or it can't merge without an admin override.
Resolving a thread doesn't trigger workflows, so after resolving run it by hand:

```sh
gh workflow run codex-review.yml -f pr=<number>
```
