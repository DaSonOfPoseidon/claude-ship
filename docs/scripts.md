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
| `failure` | a Codex thread is unresolved, or Codex's review failed (on a fork PR, with a message that a retry won't help) |
| `pending` | no completed review of the head yet, or the review stalled, was never acknowledged, or can't be tied to a request |

On a fork PR the owner can also set `success` without a Codex review (below).

A failed review stands only until a newer trusted request (#184): the retry is then running, so the status reads
as `pending` (waiting, not acknowledged, or stalled, as above) instead of the old failure. The failure's time is
the summary's last edit, and a request in the same second counts as before it. Right after `codex-request.sh`
the summary still shows the failed row, and `codex-wait.sh` used to return that stale failure at once.

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

**Not acknowledged.** Sometimes Codex never picks a request up at all (#133): no 👀, no summary edit, nothing.
Without a rule the wait ran its full 20 minutes and the user had to step in. The status is `pending` and says
so when the latest trusted request came after the head's push (or in the same second, as `codex-request.sh` counts it), is `CODEX_ACK_SECS` (default 300) old, and
Codex has shown no sign of it since: no summary edit, no 👀 of its own on the request, no receipt and no review
after it. Codex removes its 👀 when a review finishes, and where it puts the 👀 while a review runs isn't
verified, so any bot activity after the request counts and the 👀 only adds to it. A tie in the second counts
as a sign of life. Anyone can react, so only the bot's login counts. The reactions, receipts and reviews are
read only for a request this old (the list of requests shows a 👀 count, and the call is skipped when it is
0), so a normal run makes no extra call. A stall (above) keeps its own message when both apply, and a retry
that is only a minute old is waiting, not unacknowledged. The output contract of the action is unchanged: the
state is still `pending`.

**Fork PRs (#126).** Codex's review of a fork PR fails upstream (openai/codex#47577), and a fork PR's own
`pull_request` run gets a read-only token that can't set a status, so the workflow skips that run (below). The
script treats a PR as a fork when its head repository differs from the base (names compare without regard to
case) or is gone (a deleted fork, whose push activity can't be read either). Same-repo PRs behave exactly as above
and never read approval comments. For a fork PR the order is:

1. an unresolved Codex thread fails it, as always: an approval doesn't override findings;
2. an owner approval makes it `success`: "Owner approved <sha> for merge (fork PR)";
3. a failed Codex review fails it with "Codex can't review fork PRs (openai/codex#47577); owner: comment 'Okay to
   merge' to approve <sha>", since another `@codex review` won't help;
4. otherwise the rules above apply unchanged (a clean review of the head is still `success`).

An approval is a comment whose whole body, after trimming whitespace and one trailing `.` or `!` and ignoring
case, is one of `Okay to merge`, `Approved for merge`, `Ready for prod` or `Owner approved` (the list is
`approval_phrases` at the top of the script). It is short and deliberate, and because the whole comment must match
it doesn't fire from conversation ("Okay to merge after CI" doesn't count). The comment must come from
`author_association == "OWNER"` and a user that isn't a `Bot`, and its `created_at` must be strictly after the
head's push time (the same rule as a review), so an approval of an older head doesn't carry over to a new push.
`created_at`, not `updated_at`: editing a comment doesn't move it past a push. Members and collaborators can't
approve, the same trust line as `@codex review`.

**Errors.** Each GitHub call is its own assignment, so `set -e` stops on a failed call; reading a pipeline's last
exit status would turn an empty result into "no findings".

## `skills/ship/ci-failures.sh`

Sends CI failures to the implementer instead of the main session (#118). `ci-failures.sh <pr> [owner/repo] [--wait]`
reads `gh pr checks --json name,state,bucket,link,workflow` and prints one block per check whose `bucket` is `fail` (or `cancel`: not green, listed with a `(cancelled ...)` line and no log fetch):
`<workflow> / <name>  <link>`, and for a GitHub Actions job (`/actions/runs/<run>/job/<job>`, both ids numbers) the
last 60 lines of `gh run view <run> --job <job> --log-failed`, indented, with the job and step columns, timestamps,
colours and carriage returns removed. Any other failed check (an external status, or a link whose ids aren't
numbers) is its name and link only, and its link is never passed to `gh`. Then `pending: <n> checks still running`
if any check is pending, and `no failed checks` when none failed (also when the PR has no checks at all).

- **The `codex-review` status is not CI.** `gh pr checks` lists it with the other checks, but it is pending until
  Codex has reviewed and failed while a Codex thread is open. Codex is requested only after the CI read, so waiting
  on it would end every round as a timeout, and a round-2 head with open threads would read as a CI failure no code
  change fixes. It is ignored by exact name (a `codex-review-lint` check still counts), as failed and as pending.
- **`--wait`** polls (`CI_WAIT_POLLS`, 18, every `CI_WAIT_INTERVAL` seconds, 30: 9 minutes plus the calls, under the
  agent's 10-minute Bash timeout) until nothing is pending, then prints as usual. `ship-codex` sets
  `CI_WAIT_POLLS=10` (5 minutes of polling), so the polls plus the failed-job log fetches, which run after the cap,
  fit well inside the Bash timeout, and calls it up to 4 times. At the cap it prints the same
  result and exits 3, so the caller tells "still running" from "settled". `gh pr checks --watch` isn't used because
  it can't exclude a check. `CI_WAIT_INTERVAL` is for the tests only; the hook allows `CI_WAIT_POLLS` for this script and no other variable.

- **`gh pr checks` exits non-zero on a failure (1) or a pending check (8): that is the result, not an error.** The
  script reads its output instead, and exits 1 only when that isn't a JSON list and isn't gh's "no checks
  reported". A log that can't be fetched (a run still going has no failed-step log yet) is a
  `(log unavailable: ...)` line, and the other checks still print.
- **Log text is untrusted.** It is only printed, cut to 400 characters a line; names, workflows and links lose their
  control characters first, so none can add a line or an escape sequence. The fields are joined with the unit
  separator, not a tab: `read` drops a leading tab, so an external status's empty workflow would shift the name
  into its place.
- **Who calls it.** `ship-codex` runs it with `--wait` before requesting Codex (once `gh pr view` shows the pushed
  head: the API lags a push, and the CI read would be the old head's), and without it after the review to fill `ci:`.
  Failed checks in the first call end the round as `outcome: ci-fail`, with the output as a `ci-failures:` block
  for the implementer (`agents/ship-codex.md`); the implementer also runs it itself when a review is clean but CI is
  red. The orchestrator runs it only in the fallback flow. `hooks/codex-bash.sh` allows it with a PR number, an
  optional `owner/repo`, and `--wait` after it.

## `skills/ship/unit-state.sh`

Tells the orchestrator where a planned unit stands when its implementer ended without a report (an error, a
usage-limit stop, a killed session) or after `/clear` (#120). Resuming used to cover only in-flight PRs, so a unit
with commits but no PR was lost. `unit-state.sh <branch> [owner/repo]` prints one `state:` line, then detail lines;
`orchestrate.md` › **A unit with no report** maps each state to an action, and that table is the only place the
actions are written.

| State | When |
|---|---|
| `merged <pr>`, `pr-open <pr>`, `pr-closed <pr>` | `gh pr list --head <branch> --state all` has a PR from this repository (a fork's PR from a same-named branch is dropped by `isCrossRepository`, and a PR without that field is exit 1): an open one if any, else the newest. Closed means closed unmerged. The orchestrator stops, not finishes, on `merged` with an `unpushed:` line. For a merged PR that line counts local commits missing from `refs/pull/<n>/head` (the PR's last head, which GitHub keeps after the merge and the branch's deletion, squash merges included), not from origin's copy of the branch, which is usually gone; if that ref can't be fetched, it is exit 1 |
| `pushed` | on origin, no PR (`ahead: <n>` commits over the default branch; `unpushed: <n>` if the local branch is further along) |
| `local <n>` | only a local branch, `<n>` commits ahead of origin's default branch |
| `diverged` | no PR, and local and origin each have commits the other lacks (`unpushed:` and `origin-only:` give the counts). With a PR the state is the PR's and a `diverged: yes` line is added |
| `none` | no branch anywhere, or one with no commits of its own |

`worktree: <path>` names the worktree that has the branch, and `dirty: yes` (or `unknown` when git can't read it,
as for a registered worktree whose directory is gone) means it holds modified or untracked files.

- **Nothing is guessed from stale refs.** The default branch comes from GitHub, not `origin/HEAD` (a local ref the
  agent controls, see `pitfalls.md`). It fetches that branch and then the unit's, each with an explicit refspec,
  and asks `git ls-remote` whether the branch is on origin at all: a remote-tracking ref left over from a branch
  origin deleted (a squash merge with `--delete-branch`) is never read. A failed fetch, `gh` call or `rev-list` is
  exit 1, not `none`.
- **The branch is data.** It comes from a plan file: it is checked with `git check-ref-format --branch` (and must
  come back unchanged, since `@{-1}` would expand), may not start with `-`, and is only ever a quoted argument.
  A bad name or repo is exit 2. A PR number is printed only when it is all digits.
- **It never changes the repo**: no switch, reset, delete or push. The fetch updates remote-tracking refs only.

## `skills/ship/codex-round.sh`

Counts the `@codex review` comments a PR has used, the way `codex-status.sh` counts requests: not from a bot, from
the owner or a collaborator, and `@codex review` as a word. A request whose review stalled doesn't count: Codex's
own 👀 is still on it after `CODEX_STALL_SECS`. Codex removes its 👀 when a review finishes (on #61's survey of
three repos, all 125 finished requests had lost it and all 14 stalled ones kept it), and anyone can react, so only
the bot's own 👀 marks a stall. A review still running past 15 minutes is left out only until it finishes; the
skill counts rounds when it requests the next, after the last has finished or stalled.

A request Codex never acknowledged (#133) doesn't count either: it is `CODEX_ACK_SECS` (default 300) old, has no
bot 👀 now, and the bot made no summary edit, receipt or review between it and the next request (or now, for the
latest). Both states are tested because Codex removes its 👀 when it finishes, so a missing 👀 alone doesn't mean
the request was dropped: the receipt, review or summary edit it left show that it ran. The window ends at the next
request because the summary keeps only its latest edit time, so an edit can vouch only for the request it
follows; a receipt or review stays and vouches for its own. A 👀 count of 0 in the comment list skips the
reactions call.

## `skills/ship/codex-request.sh`

Posts `@codex review` once GitHub shows the wanted commit as the PR's head. The wanted commit is the optional
third argument, the full 40-character SHA that was pushed (a short or non-hex one exits 2), else the current
checkout's HEAD. The argument is for callers that aren't in the checkout that pushed: the `ship-codex` agent runs
from the implementer's worktree, but an orchestrator resuming a PR doesn't (the pitfall about steps that read the
current checkout).

**Repeat-safe.** It posts nothing, and exits 0 saying so, when a request for this head is already out: the latest
trusted request (owner or collaborator, as `codex-status.sh` counts them) is no earlier than the head's last push
(from the branch's activity records, as in `codex-status.sh`), no Codex receipt or review follows it, and
`codex-status.sh` (next to it, else `scripts/`, run with `DRY_RUN=1`, `HEAD_SHA` and `REPO`) still prints the plain
`pending: Waiting for Codex to review …`. So an agent that restarts, or a second caller, doesn't spend a round on
the same head. Each leg lets a real re-request through: a request from before the push was for an earlier head;
an answered one is finished, and asking again is a deliberate new round; any other verdict (stalled, not
acknowledged, finished more than once, success, failure) is one `codex-wait.sh` reports or a result, and a new
request is what clears it. The staleness verdict is the status script's alone: the request side used a clock of
its own (age under 15 minutes) and replaced a review that was still running, since the summary had been edited a
minute ago (#139). If the status script fails, the call exits 2 and posts nothing. When no push of the head is on
record there is nothing to tie a request to, so it asks (the old behaviour).

**Round cap.** When it would post, it first counts the rounds with `codex-round.sh` (next to it); at
`CODEX_ROUND_CAP` (default 3) or more it posts nothing and exits 4. The check comes after the repeat check on
purpose: a request already pending for this head is round 3's own review, which must still be waited for, so it
exits 0, not 4. Putting the cap in the script lets `ship-codex` hand a retry after an exit 3 to the same call and
learn the cap and the new round from it, instead of every caller counting first. The user lifts it for a later
round by setting `CODEX_ROUND_CAP`.

## `skills/ship/codex-triage.sh`

Applies a round's triage in one call, so the orchestrator spends one turn on it instead of one per reply, issue
and resolve (each turn re-reads its whole context, #71). It is run by whoever triages: in orchestrated mode the
orchestrator, since subagents can't resolve threads (#100), from the checkout `p3-issue.sh` should read.

- **Input** is a JSON array written with the Write tool, so reply text never passes through shell quoting. Each
  entry has `thread`, `outcome` (`not-valid`, `issue`, `fixed` or `resolve`), `reply` (required except for
  `resolve`), and `issue` (`file`, `title`, `body`) exactly when the outcome is `issue`. The whole file is
  validated first: any invalid entry, or an empty array (a caller bug), exits 2 before any call.
- **Per entry**, in order: for `issue`, `p3-issue.sh` files it (found next to `hooks/`, else
  `~/.claude/hooks/`) and its URL is appended to the reply; then the reply (`addPullRequestReviewThreadReply`),
  then `resolveReviewThread`. Both are on the gate's mutation allowlist. The reply goes in as a `-f` variable,
  never in the query text and never `-F` (which reads a value starting with `@` as a file), so quoted Codex
  text can't alter the mutation.
- **A `fixed` entry** replies and resolves too. In orchestrated mode the implementer has already replied on the
  threads it fixed, so the orchestrator puts those in the same file as `resolve` entries: only
  `resolveReviewThread` runs for them, and any `reply` on them is ignored.
- **Stops at the first failed call**, printing `done:` (the threads finished) and `failed:` (the thread and
  step) to stderr, exit 1. A failed reply may have posted and a failed resolve leaves a posted reply, so check
  the thread before rerunning with the finished threads removed from the file.
- **Ends with the status recheck** (`gh workflow run codex-review.yml`) only when no entry is `fixed`: a fix
  means a push and a new request, which recheck it anyway. A `resolve` entry doesn't count, because its fix was
  pushed before the thread was resolved, so the push-triggered run saw it open; without the recheck the status
  could stay `failure` over resolved threads (at round 3 no next request follows).

## `skills/ship/codex-wait.sh`

Runs `codex-status.sh` with `DRY_RUN=1` every 60 seconds. A status that only a new request clears (stalled, not
acknowledged, or finished more than once) ends the wait with exit 3, so it isn't read as "not done yet" until the cap. Any failure
of the status script ends the wait with its error.

## `skills/ship/token-report.sh`

Reads only this repo's transcripts, the gate's cost log and `gh`, keeps no state and calls no model.

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

**Gate runs** (#110). The gate's reviewers leave no transcript, but `hooks/review-gate.sh` appends one row per run
to `~/.claude/state/review-costs.jsonl` (`$CLAUDE_REVIEW_COSTS` overrides the path, for tests). Each PR gets `gate
<stage>` rows (grouped by stage and model; the token columns show `-`, the cost is the sum of `cost_usd`), counted
in the total's requests and cost. A run with `cost_usd: null` makes its row and the total `?`, and a run that
failed (`rc` not 0) still counts. A row is the PR's when its repo is this one (compared without case: the gate logs the slug as spelled in the push
URL, `gh` gives GitHub's) and either its `head` is one of the
PR's commits (from the `gh pr view` call that reads the window, no extra call) or its head is no commit of any PR
read (the asked ones and the author's others) and its `date` is in the PR's own window (the widening doesn't
apply: the gate runs at a push), which catches heads since rewritten by an amend or rebase. Where own windows
overlap the latest-started takes it, as for requests, and a head that is another PR's commit never counts by
window. A missing log means no gate rows. A line that isn't JSON or lacks `repo`, `head`, `stage` or `date` is
skipped with one stderr warning giving the count, so a corrupt log isn't read as cheap; a log that exists but can't
be read is an error.

**Prices.** USD per MTok, from the claude-api skill's `shared/models.md` (cached 2026-10-06). `w5` and `w1` are
the 5-minute and 1-hour cache writes; `big` replaces `std` when a request's prompt (input + cache read + cache
write) is over 100k tokens. Issue #70 says Sonnet cache reads cost $0.10; the skill docs say $0.20.

**Records.** A request spans several transcript lines, so the one with the most output is kept. Cache writes use
the 5m/1h split, with any remainder of the total priced as 5m. Costs are integer nano-dollars (tokens x $/MTok x
1000), so rounding to the cent is exact. Times are cut to `YYYY-MM-DDTHH:MM:SS` (transcripts carry milliseconds)
and compared as text.

## `skills/ship/gate-stats.sh`

Shows whether the gate pays for itself (#117). `gate-stats.sh <pr>...`, or `--since YYYY-MM-DD` for the author's PRs
created on or after that date (`gh pr list --author @me`, newest 200, oldest first printed; a full page of 200 warns
that older PRs in the range may be missing). Run from a checkout of the repo. It is read-only: it reads the gate's
local state, its cost log, `gh` and `jq`, and writes and calls nothing. A table row per PR, a `total` row and three
rates:

- **codex**: the PR's review threads whose first comment is Codex's, resolved or not (the query is
  `codex-findings.sh`'s without the unresolved filter, since triage resolves them).
- **caught / rejected / missed**: each Codex thread is *caught* if a gate finding that stands (not rejected by the
  verifier, any severity) is in the same file within 10 lines of the thread's line (`line`, else `originalLine`);
  *rejected* if only rejected findings are; else *missed*. A thread with no path or no line is missed, and so is a
  finding whose line the report doesn't give as a number (it matches nothing).
- **heads**: the PR's commits the gate saw: those with a report (`<head>.md`) or a waiver (`<head>.waived`) in
  `$(git rev-parse --git-common-dir)/review-gate`. **waived**: heads with a waiver. **blocks**: heads that weren't
  waived and whose report has a P0, P1 or P2 finding that isn't rejected, which is the rule `blocking_of` applies
  (`hooks/review-lib.sh`). The gate keeps no verdict file, so the rule is read off the report's findings.
- **cost**: the sum of `cost_usd` over the cost-log rows for this repo (compared without case) whose head is one of
  the PR's commits. A row whose cost isn't a number makes the cost `?`; a line that isn't a row is skipped with one
  warning, as in `token-report.sh`.
- **Rates**: miss = missed / codex, waiver = waived / heads, block = blocks / heads, over the PRs with gate state
  (`-` when the denominator is 0).

**Limits.** The state is local: a PR reviewed from another clone, or before the gate, has no heads here. Its row shows
`-` in the gate columns, a stderr note names it, and the total and the rates leave it out (its codex count is shown
but not added). A head that an amend or rebase rewrote isn't in the PR's commits, so its report and cost aren't
counted. The ±10-line match is a heuristic:
it can call a thread caught because the gate flagged something else nearby, or missed because the code moved.
A commit id from `gh` is used as a file name only when it is 40 to 64 hex digits. Reports are read by their
`## <severity>[ (rejected by the verifier)]: <file>:<line>` headings (`hooks/review-gate.sh` writes them).

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

A workspace (the git toplevel, else the cwd) whose `AGENTS.md` or `CLAUDE.md` has `- mode: local` in its
`## PR loop` section gets the local loop's hint instead, before any `gh` call or variable lookup (claude-ship #82).
The section runs from its heading to the next `## `, and lines in HTML comments or code fences don't count, so the
commented block in `templates/AGENTS.md` doesn't opt a repo in. The scan is a state table (in the hook's comment)
in which a fence and a comment each treat the other's markers as literal text: `<!--` inside a fence starts nothing,
a fence line inside a comment starts nothing, and a fence ends only on its own character at the opener's length or
more (`tests/orchestrate-hint.sh` has a case per cell; claude-ship #159). The hook reads only those two files, never runs
or quotes them (the hint holds just the directory, encoded by `jq`), and keeps the same mark, per session and
workspace. Without the marker, a directory that isn't a git repo still gets nothing.

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

## `hooks/codex-bash.sh`

A PreToolUse hook in `agents/ship-codex.md`'s frontmatter, for its Bash and Write (claude-ship #132). The agent
runs a Codex round from PR text and Codex's findings, which can steer it. Unlike `explorer-bash.sh` (which
exits 0 to say "no objection"), this one prints an allow decision, which pre-approves the call for this agent
only: without it, auto mode would deny a subagent the calls the round needs (#100). So it is an **allowlist of
exact commands**, not a list of what is dangerous, and a hook's `allow` is a grant, not an absence of a deny.
Whether the allow also skips auto mode's check is confirmed only on an installed run; the tests cover what the
hook decides, not what Claude Code does with it.

- **Same word discipline as the explorer hook.** The command may hold only letters, digits, space and
  `_./:=,@%+^~-`, so the words checked are the words that run. The first word is then an installed script path
  written with `~/` exactly (not `$HOME`, an absolute path, `./`, `..` or `env`/`sh`), or `gh`, or the one
  environment prefix below.
- **Allowed, as one plain command.** `codex-round.sh <pr> [owner/repo]`, `codex-request.sh <pr> <owner/repo>
  <sha>`, `[CODEX_WAIT_SECS=<n>] codex-wait.sh <pr>`, `codex-findings.sh <pr>`, `[CI_WAIT_POLLS=<n>] ci-failures.sh <pr> [owner/repo [--wait]]`, `codex-triage.sh <pr> <file>`, and
  `gh pr view|checks <pr> ...`. `--wait` is the one option `ci-failures.sh` takes, and only as its third word,
  after the repository (`ci-failures.sh 12 --wait` and `ci-failures.sh 12 o/r --wait extra` deny). `<pr>` is up to nine digits, a slug is `owner/repo` of letters, digits and `_.-` only,
  with no part starting with `-`, no part that is `.`, and no `..` anywhere, a sha is 40 lowercase hex characters. Nothing else may precede or follow: any other variable
  (`PATH=`, `GH_TOKEN=`, `CODEX_REQUEST_TRIES=`) denies, `CODEX_WAIT_SECS` only before the wait, and `CI_WAIT_POLLS`
  (digits, one to nine) only before `ci-failures.sh`; only one of the two may be given.
- **A poll is denied with a hint.** The agent runs `CODEX_WAIT_SECS=300 codex-wait.sh <pr>` in the foreground,
  up to 4 calls in a row, and never ends its turn before one gives a result, so its report reaches the
  implementer and not the orchestrator (claude-ship #147). A command that starts with `sleep`, `cat`, `tail` or
  `head` still denies like any other, but the reason adds "don't poll: run codex-wait.sh again in the foreground,
  and never end your turn before it returns a result" (claude-ship #142, #147). It allows nothing new.
- **A backgrounded call is denied.** A Bash call whose `run_in_background` is anything but absent, `null` or
  `false` (so `true`, `"true"` and `1` too) denies, whatever the command, with the hint "Run it in the
  foreground (no run_in_background), and never end your turn before it returns a result." The prose rule in
  `agents/ship-codex.md` was not enough: the agent still backgrounded its waits and ended its turn, so the
  implementer got an interim result (claude-ship #171). A Write ignores the field.
- **gh.** Only `pr view` and `pr checks`, after a PR number. `--web`, and any short option cluster holding `w`,
  deny, as does the same word after a `--` (which can be an option's argument), so every word is checked.
- **The triage file** lives in a fixed directory, `~/.claude/state/claude-ship/`, named
  `triage-<owner>+<repo>-<pr>.json` (the slug's `/` written `+`, which a slug can't contain, so the name reads back
  one way). An earlier version used the checkout's git common directory, whose path went into the command: a path
  with a space split into two words, and the quoting that would fix it is exactly what the character check
  refuses (Codex, #137). The fixed directory keeps every checkout path out of the command. `codex-triage.sh`
  takes the file written with `~` (the shell expands it, so a home path with a space is still one word), and
  only with the PR's own number; Write takes the same file as an absolute path under `$HOME`, nothing else
  (no `..`, no other directory, no subdirectory, no other name; the name's repository part must read back as a
  valid slug, with exactly one `+`). The state directory is outside the gate's protected paths (hooks, settings,
  `skills/ship`, `agents/ship-*`), and holds nothing the gate or the loop reads. A Write's content isn't the
  hook's to judge: `codex-triage.sh` validates the file. With no `HOME`, a Write denies.
- **Fails closed.** Input that isn't JSON, has no string `tool_name`, `tool_input.command` (Bash) or
  `tool_input.file_path` (Write), or names any other tool, exits 2 with a reason the agent sees. A hook that
  fails to run at all (missing, not executable) doesn't deny: Claude Code reads that as a non-blocking error and
  the call goes on to the normal permission check, which is not an allow. The deployed mode is tested.
- **The gate still sees these commands.** The pre-push gate's own hook runs on the same calls; a deny from either
  wins over this allow. Every write the agent makes is through a ship script the gate's `gh api` allowlist
  already covers.

## `hooks/review-lib.sh` and `tests/evals/run.sh`

`review-lib.sh` holds what the gate and the eval runner share: the prompt builders, the two output schemas, the
reviewer run (`run_claude`, with its flags and cost row) and the rules that turn verdicts into findings and a block
count. It is sourced, never run, and reads the caller's variables (named in each function's header) instead of taking
a dozen arguments; shellcheck can't follow the sourcing, so both files disable SC2034 and SC2154. Its functions return
a status or print nothing on failure and never exit, because the gate turns that into a block and the runner into an
`error` row. `tests/gate-lib.sh` checks that the prompt the gate writes is the one `build_prompt` writes for the same
inputs.

`tests/evals/run.sh` measures the reviewers (design notes and scoring: [`gate.md`](gate.md#changing-prompts-or-models)).
Its inputs come from the case's `base` commit through the same `rules_of` and `checklist_of` the gate uses, never
from the working tree it runs in (the pitfall of a step reading the current checkout). It sets the gate's inputs
for a first review: no PR, no threads, no filed issues. A run that is interrupted removes its worktree and temp
directory in a trap.

## `install.sh`

Only `origin/main` is deployed, so what runs has passed review. That holds for the installer too: after
fetching, it runs main's copy of itself, so a checkout behind main still deploys what main's installer knows to
(#20). The gate's hook entry lives in `~/.claude/settings.json` (see the README).

After deploying, it reads that file (never writes it; only the user edits the settings that register the gate) and
compares the gate's entry with the README snippet from `origin/main`, so the expected values have one source. A
`matcher`, `timeout` below the README's or `onFailure` other than `"block"` that differs gets a warning (exit 0)
and the README's entry to paste. It exits 1 when the gate isn't registered at all (no file, invalid JSON, no
`PreToolUse` hook running `~/.claude/hooks/review-gate.sh` or the absolute path in the target directory) or when
it can't check (no `jq`; a README without the snippets, which would be a bug here). The orchestrate hint hook is
optional: a missing one only prints an info line. So does a missing `"env": {"CLAUDE_CODE_FORK_SUBAGENT": "0"}`
(only the string `"0"` counts): the PR loop needs it, because under fork mode a subagent's Agent call returns at
once (#160).

After the files, it runs `scripts/fetch-shfmt.sh` from main's archive to put shfmt at `$dest/bin/shfmt` (#135). A
failure prints `couldn't install shfmt` and makes the exit non-zero, but the rest of the install still runs, so the
gate and the skill are deployed either way.

## `scripts/fetch-shfmt.sh`

`scripts/fetch-shfmt.sh <dest-file>` installs shfmt v3.14.1, the shell parser the gate's tamper check uses (#135),
on Linux x86_64 or aarch64/arm64 (anything else exits 1). `install.sh` calls it for `~/.claude/bin/shfmt`, and CI
for the same path before its tests.

- **Pinned hash.** mvdan/sh publishes no checksum file, so the script holds a sha256 per asset, computed by
  downloading each official asset and running `sha256sum` on it. A download that doesn't match is discarded: exit 1,
  an existing `<dest-file>` untouched, no temp file left. There is no option to skip or override the check, and the
  tests swap the pins in a sed-edited copy of the script instead.
- **Atomic.** The download goes to a temp file next to `<dest-file>`, so the final `mv` replaces it in one step,
  and the file is never piped into a shell. Only `https` is followed (`--proto`, `--proto-redir`).
- **Already current.** A `<dest-file>` with the pinned hash is left alone and nothing is downloaded, so re-running
  `install.sh` costs no network. It still sets the mode to 755 (a copy that lost its execute bit would otherwise
  stay unusable), and fails if that chmod does.
- **Exit codes.** 0 installed or current; 1 unsupported machine, no `sha256sum`/`shasum`, download failure or
  mismatch; 2 usage (no or extra arguments), since `set -u` would have said 1, which reads as a result.

## `action.yml` and the workflows

The status script is the action's own copy, at the ref the caller names (`@v1`, a tag moved on release), so
nothing in the calling repo, including a PR's changes, decides it. The bot-only filter, the per-PR concurrency
and the action call live in the reusable workflow `.github/workflows/codex-status.yml`, which callers reference
at the same `@v1`, so one fix reaches every repo when the tag moves (before, each repo carried a 46-line copy
that went stale). Triggers and permissions stay in the short caller (`skills/ship/templates/codex-review.yml`),
since a called workflow can't set triggers or exceed its caller's permissions. This repo's own caller uses the
local path (`./.github/workflows/codex-status.yml`), so a PR exercises the new file before `v1` moves.

The job skips a `pull_request` run whose head is in another repository: a fork PR's token is read-only, so that run
could only fail with a 403 and a red check (#126). A fork PR's status comes from the other triggers instead, which
run the default branch's workflow with the caller's permissions: Codex's own comments and reviews, a dispatch run,
and an `issue_comment` whose `author_association` is `OWNER`, so the owner's approval phrase takes effect at once.
That `if:` is only a filter (anyone can comment); the script checks who and when again. The template's triggers
already include `issue_comment`, so callers need no change; they get this when the owner moves `v1`. No new
permission is needed, and there is no `pull_request_target`.

Inside a called workflow `github.event` is the caller's event, so the PR number expressions work as before. The
`inputs` context there is the workflow's own `workflow_call` inputs, not the caller's dispatch inputs, so a
dispatch run's number is read from `github.event.inputs.pr`. The action step stays `@v1` rather than `./`: a
called workflow has no checkout of claude-ship, and `./` would mean the caller's repo. A dispatch run uses the
default branch's caller, so that path can only be checked after a change merges.

The check run is named `codex-review / codex-status` (caller job / called job). The required `codex-review`
commit *status* the script sets is unchanged, and it is what branch protection reads.

`v1` moves (owner only) when claude-ship releases, which changes the check in every caller without a PR there. A
PR that changes the ref needs write access.

A repo's first PR (the one that adds the workflow) can't rely on the status: Codex reports a clean review by
editing a comment, which runs the default branch's workflow, and that branch doesn't have it yet. Require
`codex-review` in branch protection only after that PR merges, or it can't merge without an admin override.
Resolving a thread doesn't trigger workflows, so after resolving run it by hand:

```sh
gh workflow run codex-review.yml -f pr=<number>
```
