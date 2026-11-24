# The helper scripts: design notes

Each script keeps a short header (what it does, its arguments and exit codes) and brief comments on its checks;
the reasons behind them are here. The gate's notes are in [`gate.md`](gate.md), classes of bug past reviews
caught are in [`pitfalls.md`](pitfalls.md), and the label map and variables `p3-issue.sh` reads are in the
[README](../README.md#per-repo-opt-in).

## `scripts/codex-status.sh`

The only copy of the status script. Repos run it through this repo's action (`action.yml`, called at `@v1`), and
`install.sh` deploys it into the ship skill for local checks. It sets the status only in GitHub Actions
(`GITHUB_ACTIONS` exactly `true`, which GitHub sets on every step, so the action posts as before). Anywhere else it
prints the status and says on stderr that it set nothing: run by hand, it would post as the user, branch protection
requires the status from Actions, and the newer one blocks the merge (#290, #291). `CODEX_STATUS_SET=1` sets it by
hand anyway, for debugging the action from a shell. `DRY_RUN=1` never sets it, in Actions too (and adds no stderr
note); `HEAD_SHA` checks another commit, to test against past reviews.

| State | When |
|---|---|
| `success` | Codex completed a review of the head commit after it was pushed, and every Codex review thread is resolved |
| `failure` | a Codex thread is unresolved (unless a request for the head is still unanswered, below), or Codex's review failed (on a fork PR, with a message that a retry won't help) |
| `pending` | no completed review of the head yet, or the review stalled, was never acknowledged, or can't be tied to a request, or Codex's summary says it finished with findings and the review carrying them hasn't posted (stalled if it never does) |

On a fork PR the owner can also set `success` without a Codex review (below).

A failed review stands only until a newer trusted request (#184): the retry is then running, so the status reads
as `pending` (waiting, or not acknowledged, as above) instead of the old failure. The failure's time is
the summary's last edit, and a request in the same second counts as before it. Right after `codex-request.sh`
the summary still shows the failed row, and `codex-wait.sh` used to return that stale failure at once.

Resolve a thread once its finding is fixed, or answered with why it doesn't apply.

**An unanswered request outranks open threads (#282).** The verdicts are decided in this order: an unanswered request
for the head, then an unresolved Codex thread, then the rest (an owner's fork approval, findings still posting, a
completed review, a failed one, a stall, finished more than once, not acknowledged, waiting). A request is
*unanswered* when the latest trusted request came at or after the head's push and no Codex receipt or review follows
it (strictly after, to the second, as `codex-request.sh` counts them). Then the status is `pending` whatever threads
are open: findings still posting, then a review that failed (still a `failure`, so it can be retried), then stalled, then not acknowledged, else "Waiting for Codex to review …". Without
this, threads left by an earlier round hid a running review behind `failure`: `codex-wait.sh` returned at once, and
`codex-request.sh` asked a second time for the same head, which spent a round (#280). The receipts and reviews are
read only with threads open and a request for the head, so a normal run makes no extra call. Once Codex answers
(any receipt or review after the request), the threads fail it as before; with no request since the head's push,
they fail it too.

**Push time.** Codex's summary names commits by a 7-character SHA, which someone could forge a collision for, so
a review counts only if it finished after the head was last pushed. The push time comes from GitHub's own
activity records for the branch (`push`, `force_push`, and `branch_creation` for a new branch's first push).

**The summary.** Codex keeps one summary comment per PR and edits it as reviews run. Its Code Review row names
the commit it reviewed and the status. A hidden `codex-review-state:v1` JSON marker in it says whether a review
is running (`status`: `running` or `completed`) and whether it found anything (`has_any_findings`).

**Findings still posting (#229).** Codex can mark the summary completed before it posts the review whose threads
carry the findings (seen on OBDCracker #289). A completed row alone would then read "no findings" with the threads
still to come, and the loop could merge before they land. So when the state JSON names the head, says `completed`
and has `has_any_findings: true`, the status stays `pending` ("Codex finished <sha> with findings; waiting for its
review to post") until a Codex review of the head has been submitted at or after the later of the latest trusted
request and the head's push (times to the second, as text; an unsubmitted review has no time and doesn't count).
The review event re-runs the status, which then fails on its open threads, or succeeds if they are all resolved.
A review of another commit, or of the head from before the latest request (a re-review), doesn't end the wait. A
`has_any_findings` that is false or null, a state that names another commit or none, and a state that isn't JSON
change nothing. An unresolved Codex thread still fails first (unless a request for the head is unanswered, above), an owner's fork approval still wins over the wait,
and the reviews are read only in this case. `codex-wait.sh` keeps waiting on it, as on any plain `pending`.
When the summary's last edit, the latest trusted request and the push are all `CODEX_STALL_SECS` old and the review
still hasn't posted (#231), the status stays `pending` but says so ("... its review never posted (stalled, no update in N min);
ask again with @codex review"), and `codex-wait.sh` exits 3 on it like on any stall.

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

**Reads (#111).** A run reads each endpoint at most once, and every value comes from that one snapshot: the PR
(`pulls/<pr>`: the head's sha, repository and ref together), its comments (`issues/<pr>/comments`) and the reviews
(`pulls/<pr>/reviews`, only when a path needs them, then kept). Two reads are not one snapshot: a push between two reads
of the PR paired one head's sha with another's repository, and an edit between two reads of the comments paired a
summary's body with another read's `updated_at`. The comments come back as tagged lines, one filter per tag
(`S` summary, `R` trusted request, `C` receipt, `A` owner approval; a comment that several filters select yields a
line for each), and the script splits them with `sed`. The filters stay in gh's `--jq`, not in the local jq: gh runs
gojq (Go regexp), the host's jq is Oniguruma, and `\s`, `\b` and Unicode can differ, which would change which comments
count as a trusted request or an owner's approval. The local jq only decodes a summary's body, which travels as one
line of JSON (so a newline in it can't forge a tag). Each read is its own assignment, so `set -e` stops on a failed
call before anything is posted; reading a pipeline's last exit status would turn an empty result into "no findings".

## `skills/ship/ci-failures.sh`

Sends CI failures to the implementer instead of the main session (#118). `ci-failures.sh <pr> [owner/repo] [--wait]`
reads `gh pr checks --json name,state,bucket,link,workflow` and prints one block per check whose `bucket` is `fail` (or `cancel`: not green, listed with a `(cancelled ...)` line and no log fetch):
`<workflow> / <name>  <link>`, and for a GitHub Actions job (`/actions/runs/<run>/job/<job>`, both ids numbers) the
last 60 lines of `gh run view <run> --job <job> --log-failed`, indented, with the job and step columns, timestamps,
colours and carriage returns removed. Any other failed check (an external status, or a link whose ids aren't
numbers) is its name and link only, and its link is never passed to `gh`. Then `pending: <n> checks still running`
if any check is pending, and `no failed checks` when none failed (also when the PR has no checks at all).

- **The `codex-review` status is not CI.** `gh pr checks` lists it with the other checks, but it is pending until
  Codex has reviewed and failed while a Codex thread is open. Waiting on it would never settle while Codex is still
  reviewing, and a round-2 head with open threads would read as a CI failure no code change fixes. It is ignored by exact name (a `codex-review-lint` check still counts), as failed and as pending.
  So is the reusable workflow's job that sets it, which `gh` lists as `codex-review / codex-status` (the caller's job
  id, then `/ codex-status`; a bare `codex-status` too): it can fail on a transient gh API error with CI green, and
  that must not end the round as a CI failure (#228). The match is on the job name, not the workflow name
  (`Codex review` is set per repo), and a `codex-status-lint` check still counts.
- **`--wait`** polls (`CI_WAIT_POLLS`, 18, every `CI_WAIT_INTERVAL` seconds, 30: 9 minutes plus the calls, under the
  agent's 10-minute Bash timeout) until nothing is pending, then prints as usual. `ship-codex` runs it after the
  review (step 5, once the review wait has a result), with `CI_WAIT_POLLS=10` (5 minutes of polling), so the polls
  plus the failed-job log fetches, which run after the cap, fit well inside the Bash timeout, and calls it up to 4
  times. At the cap it prints the same
  result and exits 3, so the caller tells "still running" from "settled". `gh pr checks --watch` isn't used because
  it can't exclude a check. `CI_WAIT_INTERVAL` is for the tests only; the hook allows `CI_WAIT_POLLS` (1 to 10) for this script and no other variable.

- **`gh pr checks` exits non-zero on a failure (1) or a pending check (8): that is the result, not an error.** The
  script reads its output instead, and exits 1 only when that isn't a JSON list and isn't gh's "no checks
  reported". A log that can't be fetched (a run still going has no failed-step log yet) is a
  `(log unavailable: ...)` line, and the other checks still print.
- **Log text is untrusted.** It is only printed, cut to 400 characters a line; names, workflows and links lose their
  control characters first, so none can add a line or an escape sequence. The fields are joined with the unit
  separator, not a tab: `read` drops a leading tab, so an external status's empty workflow would shift the name
  into its place.
- **Who calls it.** `ship-codex` requests the review first (once `gh pr view` shows the pushed head), so CI runs
  alongside it (#255), and runs this with `--wait` after the review, if `gh pr view` still shows the pushed head
  (a newer push means one read without the wait, since the checks are the new head's). Failed checks go in the
  report's `ci-failures:` block with whichever outcome the findings give, so the implementer fixes them together with
  the findings in one push (`agents/ship-codex.md`). In its resolve-only and triage-only modes it reads without the
  wait. The orchestrator runs it only in the fallback flow. `hooks/codex-bash.sh` allows it with a PR number, an
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
as for a registered worktree whose directory is gone) means it holds modified or untracked files (git-ignored files don't count).

- **Nothing is guessed from stale refs.** The default branch comes from GitHub, not `origin/HEAD` (a local ref the
  agent controls, see `pitfalls.md`). It fetches that branch and then the unit's, each with an explicit refspec,
  and asks `git ls-remote` whether the branch is on origin at all: a remote-tracking ref left over from a branch
  origin deleted (a squash merge with `--delete-branch`) is never read. A failed fetch, `gh` call or `rev-list` is
  exit 1, not `none`.
- **The branch is data.** It comes from a plan file: it is checked with `git check-ref-format --branch` (and must
  come back unchanged, since `@{-1}` would expand), may not start with `-`, and is only ever a quoted argument.
  A bad name or repo is exit 2. A PR number is printed only when it is all digits.
- **It never changes the repo**: no switch, reset, delete or push. The fetch updates remote-tracking refs only.

## `skills/ship/worktree-sweep.sh`

Clears the worktrees that finished units leave behind (#244): every implementer's worktree and branch outlived its
merged PR, because only the unit being merged was cleaned up. `worktree-sweep.sh [owner/repo]` runs `unit-state.sh`
on the branch of each linked worktree (it skips the main checkout, the checkout it runs in, and any worktree with
no branch, and lists them as `kept:`) and removes a worktree only when all of these hold: `state: merged`, and no
`unpushed:`, `dirty:` or `diverged: yes` line. Everything else prints `kept: <path> <branch> <reason>`; a removal
prints `removed: <path> <branch>`.

Then it clears local branches no worktree holds (#286), which the worktree pass never saw: `worktree-agent-<id>`
branches that Claude Code makes for an `isolation: worktree` agent (82 piled up), and the branches of merged PRs that
never had a worktree. Both passes compare with GitHub's default branch, fetched fresh, never with a local ref.

- **It reuses `unit-state.sh`'s facts and adds none.** `unpushed:` for a merged PR counts local commits missing from
  `refs/pull/<n>/head`, so it is right after a squash merge with `--delete-branch`, when origin's copy of the branch is
  gone. `dirty: unknown` (a registered worktree whose directory is missing) keeps the worktree too.
- **A lock does not mean a live agent.** A finished agent's worktree stays locked with the pid of the parent Claude
  session, which is still running. So the sweep ignores the lock when deciding, and unlocks it when it removes (the
  porcelain output's `locked` line; `unit-state.sh` doesn't read it). `orchestrate.md` has the caller check `ListAgents`
  for a live implementer before it sweeps. If the remove fails, the lock goes back with its reason.
- **Ignored files go with the worktree, and are listed.** `dirty:` and `git worktree remove` both ignore git-ignored
  files (build output, a `.env`), so keeping every worktree that has one would stop the sweep for good. Just before the
  remove it reads `git status --porcelain --ignored=traditional` (an ignored directory counts as one entry) and, after
  the removal, prints `deleted-ignored: <path> <n> path(s): <the first five>` (with ` …` when there are more). If git
  can't read them, the worktree is kept (`kept: … ignored files unreadable`), as `dirty: unknown` keeps it.
- **The removal order is unlock, `git worktree remove`, `git branch -D`.** No `--force`: git refuses a worktree with
  modified or untracked files (not ignored ones, see above), a second guard after the `dirty:` check. `-D` is needed because a squash merge leaves
  the branch unmerged by SHA, and it runs only after the remove succeeded. It ends with `git worktree prune`.
- **The agent pass** deletes a `worktree-agent-*` branch (`deleted: <branch>`) when `git merge-base --is-ancestor` finds
  its tip on `origin/<default>`, and prints `kept: - <branch> commits not on origin/<default>` when it isn't. It is
  `-D` after that check, not `-d`: `-d` compares with HEAD or the upstream, which in the user's checkout may be another
  or a stale branch, and would refuse a branch the check just proved merged.
- **The merged-branch pass** runs `unit-state.sh` on every other local branch and deletes it (`deleted: <branch>`)
  only for `state: merged` with no `unpushed:` and no `diverged:` line; with one of those it prints `kept: - <branch>
  <reason>`. Any other state is the user's or a live unit's work, and prints nothing, so the `kept:` lines the loop
  passes to the user stay few. It costs two `gh` calls per local branch.
- **Never touched by either pass:** the default branch, and any branch a worktree has checked out (read from
  `git worktree list` after the worktree pass, and before the prune, so a worktree whose directory is gone still holds
  its branch; a branch in the middle of a rebase lists as detached, so each `rebase-merge/head-name` and
  `rebase-apply/head-name` names one too). A name `unit-state.sh` rejects (exit 2) is skipped.
- **Fail closed.** A `unit-state.sh`, `gh` or `git` failure is exit 1 and stops the sweep at once: nothing further
  is removed, and no prune; what an earlier pass removed stands (the default branch or the fetch failing, for
  instance, stops it before the branch passes). Exit 0 means it ran to the end, whether or not it removed anything;
  exit 2 is usage.

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
the cap or more it posts nothing and exits 4. The cap is 3, and only the user raises it, with
`codex-allow.sh` (next section): when `<Claude home>/claude-ship/codex-allow/<owner>+<repo>-<pr>` holds a plain
positive integer above 3 (digits only, nine at most, one line), that is the cap for the PR. A missing, empty or
malformed file, or a number of 3 or less, leaves the cap at 3 (fail closed: no extra round). The environment no
longer raises it: `CODEX_ROUND_CAP` is gone, since an agent could set it itself (the #280 orchestrator did). The
exit-4 message names the cap and the command that lifts it. The check comes after the repeat check on
purpose: a request already pending for this head is round 3's own review, which must still be waited for, so it
exits 0, not 4. Putting the cap in the script lets `ship-codex` hand a retry after an exit 3 to the same call and
learn the cap and the new round from it, instead of every caller counting first.

## `skills/ship/codex-allow.sh`

The user's way past the round cap (#282). Usage: `! ~/.claude/skills/ship/codex-allow.sh <pr> [owner/repo]`, run
by the user with `!`; the repository defaults to the one `gh` sees in the cwd. It counts the PR's rounds with
`codex-round.sh` (next to it; a failed count exits 1 and writes nothing) and writes that count plus one to
`<Claude home>/claude-ship/codex-allow/<owner>+<repo>-<pr>` (in lower case, as `codex-request.sh` reads it, since GitHub names match without case; `CLAUDE_HOME`, else `$HOME/.claude`; the file is
written beside itself and moved into place), then prints `Allowed one more Codex round on <slug>#<pr> (cap <n>).`
Each run grants exactly one round beyond those already used, so allowing a fifth round takes a second run after
the fourth. A `pr` that is not digits, or a slug that is not `owner/repo` (two parts, no `.` or `..`), exits 2
and writes nothing. `codex-request.sh` reads the file (above).

The gate denies Claude a run of `codex-allow.sh` in every repo (`docs/gate.md` › Waivers and opt-in flags), and the directory is under
`~/.claude/claude-ship/`, which the tamper check already protects from Write, Edit and shell writes. So no agent can
grant itself a round. `ship-codex`'s allowlist (`hooks/codex-bash.sh`) does not include the script either.

## `skills/ship/codex-triage.sh`

Applies a round's triage in one call, so the orchestrator spends one turn on it instead of one per reply, issue
and resolve (each turn re-reads its whole context, #71). It is run by whoever triages: in orchestrated mode the
orchestrator, since subagents can't resolve threads (#100). Usage: `codex-triage.sh <pr> <triage.json> [owner/repo]`.
With the repository it runs from any checkout of it (claude-ship #140): `ship-codex` can't `cd`, so it runs in
whatever checkout its parent was in. It passes the PR to `p3-issue.sh`, so the milestone comes from GitHub and not
from the cwd's branch.

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
  step, or `recheck (workflow)`) to stderr, exit 1. A failed reply may have posted and a failed resolve leaves a
  posted reply, so check the thread before rerunning with the finished threads removed from the file. When
  `failed:` is `recheck (workflow)`, every thread is already done: run only `gh workflow run codex-review.yml -R
  <slug> -f pr=<pr>` again (or push a commit), never the triage file, which would be empty and exit 2.
- **Ends with the status recheck** (`gh workflow run codex-review.yml`) only when no entry is `fixed`: a fix
  means a push and a new request, which recheck it anyway. A `resolve` entry doesn't count, because its fix was
  pushed before the thread was resolved, so the push-triggered run saw it open; without the recheck the status
  could stay `failure` over resolved threads (at round 3 no next request follows).

## `skills/ship/codex-wait.sh`

Usage: `codex-wait.sh <pr> [owner/repo]`. Runs `codex-status.sh` with `DRY_RUN=1` every 60 seconds. With the
repository it sets `REPO` for it, so nothing reads the cwd (`ship-codex` can't `cd`, claude-ship #140); without it
`codex-status.sh` asks `gh` for the cwd's repository. `codex-findings.sh <pr> [owner/repo]` has the same optional
argument. A status that only a new request clears (stalled, not
acknowledged, or finished more than once) ends the wait with exit 3, so it isn't read as "not done yet" until the cap. Any failure
of the status script ends the wait with its error.

## `skills/ship/agent-context.sh`

`agent-context.sh <marker>` prints how large a running subagent's context is, so the `ship-implementer` can hand a
long fix round to a fresh one (#246; `agents/ship-implementer.md` › Handoff check, `orchestrate.md` step 4). A
subagent doesn't know its own transcript, so it first writes a marker (`implementer-` and twelve hex digits) into a
Bash command. The digits come from `/dev/urandom` (`od -An -N6 -tx1`), not from the model's own pick: nine implementers
picked the same one and the check then exited 1 (#271). Claude Code keeps the command's transcript in
`<projects>/<project>/<session>/subagents/agent-<id>.jsonl` (`$CLAUDE_PROJECTS_DIR` or `~/.claude/projects`). The script finds the one subagent transcript that holds the marker,
under every project (main-session transcripts and `.meta.json` files are not searched), and prints the prompt size of
the last assistant request: input + cache read + cache write, with the write the larger of the total and the 5m + 1h
split, as `token-report.sh` takes a request's size. Records are read in file order; lines that aren't JSON, records
that aren't assistant ones with a `usage` object and `<synthetic>` ones are skipped, and a missing usage field is 0.
Exit 1, with a message, when no transcript or more than one holds the marker, when none has assistant usage, or when
`jq` fails. Exit 2 on misuse; the marker is 8 to 64 of `A-Za-z0-9_-`, not starting with `-`, so it is text for
`grep -F` and never an option. The caller treats every failure as "unknown" and carries on: a missed handoff only
costs money, and must not stop a round. Tests: `tests/agent-context.sh`.

## `skills/ship/token-report.sh`

Reads only this repo's transcripts, the gate's cost log and `gh`, keeps no state and calls no model.
`token-report.sh [--summary] [--since YYYY-MM-DD] [<pr>...]`: at least one PR number or `--since`; a bad or
repeated `--since`, an unknown option or `--summary` alone exits 2.

**`--since`** (#249) adds the repo's PRs created on or after the date (the date's midnight UTC, compared with
`createdAt` as text), whoever wrote them, oldest first, after any PR numbers given; a PR both given and selected
counts once. They come from the one GraphQL list query (newest 200) that also finds the competing PRs, so a full page warns
as before, and a selection reaching the oldest listed PR is the same error as an asked PR there (its previous PR
can't be found). A selected PR with no author can't be windowed: it is left out with a warning (an explicitly asked
one is still an error). A selection of no PR prints a note on stderr and exits 0.

**`--summary`** prints, after the per-PR tables, from the same rows (costs summed in nano-dollars, not as the
printed cents): the number of PRs with usage out of those asked; the cost by role and model across the PRs, biggest
first, with each one's share of the spend (the gate's `gate <stage>` rows are roles too); the mean, median and
max cost per PR and the five costliest PRs (ties: the lower PR number first); the mean and max peak main context;
and the implementer's (`ship-implementer`) mean cache read per request. A PR with no usage isn't in any figure. A `?`
cost is excluded per row: a `?` row is left out of the role and model table and its total, and a PR whose total
is `?` is left out of the per-PR figures (mean, median, max, top 5), with a count of those PRs (`left out of the
per-PR figures below`). That PR's priced rows still count in the role and model table, and its tokens in the peak. A PR
with no main row (the stderr warning below) is left out of the peak figures, since its 0 isn't a measurement.
Tests: `tests/token-report.sh`.

**Attribution.** A main-session request belongs to the PR whose window holds its timestamp. A PR's own window
runs from the earlier of its creation and its first commit, to the merge, else to the close of a PR closed
unmerged, else to now (open). A closed PR must not run to now, or it would swallow every later request.
The window then widens at the start (#80), because most of a PR's main-session work (planning, exploring,
implementing) comes before its first commit: the start moves back to the later of the end of the author's
previous PR (the latest merge or close before this PR's own start, among their other PRs in the repo) and the
first request of the main transcripts that have a request in the PR's own window, and never to after its own
start. The report shows the widened start. Work after the last merge isn't printed. A request inside some PR's own
window goes to the latest-started of those; only a request in none goes to the latest-started widened window, so
widening never takes work from an overlapping PR. All this is done across every PR that could matter, not just
the PRs asked for or their authors': the PRs competing for a request are the repo's, whoever wrote them (one
GraphQL query, newest first, two pages of 100 at most, so the newest 200; a full list prints a warning, since older PRs are then missing, and is an error when
an asked PR starts at or before the oldest listed one, since its previous PR can't then be found). That is the asked PRs
plus the others that could overlap an asked window (each read with `gh pr view`, since the list has only the
first commit's date, not the window; one whose author is deleted is left out), all with the same window rules. "Could overlap" is bounded on
both sides (#129). Below: a PR that ended before the earliest previous-PR end of the asked PRs is left out (no
bound when an asked PR has no earlier PR). Above: a PR whose start (the earlier of its creation and its first commit) is after the latest end of the asked
PRs (no bound while one is open) is left out too, unless the end of its own author's previous PR is before that
latest end, because its window widens back to that end and can take a request from an asked PR (#213). Both bounds
come from the list alone, which carries each PR's creation and first commit date, so no PR is read to find them. Only the asked PRs' rows are
printed, and a request won by another PR is dropped, so a PR's row is the same whichever other PRs are asked for (`tests/token-report.sh` checks this directly). A failed or odd
list (the call failing on either page, a response without the PRs, or a next page with no cursor), or an asked PR with no author (a deleted account), is an error: reading it as "no earlier PRs" would
reach the window back to the session's start. A listed PR with no author that isn't asked for is left out instead: a
competing PR silently, a PR selected by `--since` with the warning above. A whole subagent transcript belongs to the PR whose window holds its last
request: implementers start before their first commit but end after a push or a fix round. Anything else isn't
printed. A session started in a worktree logs under that directory's own slug (#248), so besides the main
checkout's transcript dir the script reads the dir of each worktree `git worktree list` shows, and every existing
`<slug>--claude-worktrees-*` dir (a removed worktree under `.claude/worktrees`: `/.claude/` in the path is
`--claude-` in the slug). Only that prefix, never `<slug>-*`, which would take in other repos (`app-foo`). Their
main and subagent transcripts go through the same window rules; the script exits 2 only when none of these dirs
exists. A removed worktree outside `.claude/worktrees` is
still missed, so a printed PR with subagent or gate rows but no `main` row prints a warning on stderr.

**Gate runs** (#110). The gate's reviewers leave no transcript, but `hooks/review-gate.sh` appends one row per run
to `~/.claude/state/review-costs.jsonl` (`$CLAUDE_REVIEW_COSTS` overrides the path, for tests). Each PR gets `gate
<stage>` rows (grouped by stage and model; the token columns show `-`, the cost is the sum of `cost_usd`), counted
in the total's requests and cost. A run with `cost_usd: null` makes its row and the total `?`, and a run that
failed (`rc` not 0) still counts when its output is JSON; a run with no JSON output (e.g. killed by `timeout`) logs no row, so its cost is missing from the report. A row is the PR's when its repo is this one (compared without case: the gate logs the slug as spelled in the push
URL, `gh` gives GitHub's) and either its `head` is one of the
PR's commits (from the `gh pr view` call that reads the window, no extra call) or its head is no commit of any PR
read (the asked ones and the others read) and its `date` is in the PR's own window (the widening doesn't
apply: the gate runs at a push), which catches heads since rewritten by an amend or rebase. Where own windows
overlap the latest-started takes it, as for requests, and a head that is another PR's commit never counts by
window. A missing log means no gate rows. A line that isn't JSON or lacks `repo`, `head`, `stage` or `date` is
skipped with one stderr warning giving the count, so a corrupt log isn't read as cheap; a log that exists but can't
be read is an error.

**Prices.** USD per MTok, from the claude-api skill's `shared/models.md` and `shared/model-migration.md` (cached
2026-11-11). `w5` and `w1` are the 5-minute and 1-hour cache writes; `big` replaces `std` when a request's prompt
(input + cache read + cache write) is over 100k tokens. Issue #70 says Sonnet cache reads cost $0.10; the skill
docs say $0.20. Priced models: Opus 5.5, 4.8, 4.7 and 4.6; Sonnet 5.5 and 4.6; Haiku 5.5 and 4.5 (#247). The
older ones have one rate at any prompt length: Opus 4.x $5 / $25, Sonnet 4.6 $3 / $15, Haiku 4.5 $1 / $5, with a
cache read at 0.1x input and writes at 1.25x (5m) and 2x (1h). A model with no price prints `?` and warns on
stderr, naming it.

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

### The review-gate state

The files the gate and `gate-stats.sh` keep in `.git/review-gate/`, who reads each, and what `review-gate.sh --prune` deletes
are in `docs/gate.md` › Pruning old state; `gate-stats.sh` reads only `<sha>.md` and `<sha>.waived` from it.

## `hooks/p3-issue.sh`

Files a finding as an issue. The finding goes in a JSON file rather than on the command line because the gate
reads a command naming `~/.claude/hooks` with a `>` anywhere in it as a write.

- **Labels** come from `CLAUDE_P3_LABELS`, plus every rule in `.github/claude-ship/p3-labels` that matches the
  finding's file, read from the default branch (a branch can't change how its own findings are filed). A matching
  rule that names an `area:` label replaces the areas of the earlier rules (so a path gets one area, an override
  goes after the broad rule, and a broad rule listed after it wins); other labels add up. Labels the
  repo doesn't have are dropped, and one that differs from a repo label only in case is filed under the repo's
  spelling. The type fallback goes by the labels that will actually be applied.
- **Milestone**, only with `CLAUDE_P3_MILESTONE=auto`: the branch's open PR's, else the one milestone of the
  issues its commit subjects fix (`fixes #N`), else none. The gate calls `p3-issue.sh <owner/repo> <finding.json>`
  from the pushing checkout, so the branch is that checkout's. An optional third argument, the PR number, reads
  both from GitHub instead (`gh pr view`: the PR's own milestone, else the one milestone of the issues named by
  `fixes/closes/resolves #N` in its commits' messages, subject and body), so it gives the same answer from any
  checkout of the repo (claude-ship #140; `codex-triage.sh` passes it).
- **The label map** is read from GitHub (`gh api repos/<slug>/contents/.github/claude-ship/p3-labels`, the default
  branch's), never from the checkout, so it is the slug's whatever repo the cwd is (claude-ship #215). A 404 means
  the repo has no map and the issue is filed with the base labels. Any other failed read (a 5xx, the rate limit,
  no network) prints `p3-issue: can't read p3-labels for <slug>: …`, exits 1 and files nothing, since an issue
  filed without its area and status labels never reaches the PR loop's queue (claude-ship #179). The status is
  the response's own status line (`gh api -i`), not a match on the error text, and a 200 counts only if `gh`
  exited 0 as well (a body cut short leaves the headers and part of the map).
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

The GitHub loop's hint adds a notice when `AGENTS.md` has no live `## PR loop` section, the only file the loop
reads its settings from (the same scan, fences and comments literal, so the template's commented block counts as
missing; a section only in `CLAUDE.md` doesn't count): the loop runs on its defaults, which Claude
tells the user once, offering to add the section from `templates/AGENTS.md` and never adding it unasked, since
`merge: yes` is a per-repo opt-in (claude-ship #260). The local loop's hint is unchanged.

## `hooks/pitfall-lint.sh`

Links `docs/pitfalls.md` to the hygiene lint's rules (claude-ship #313). It reads a repo's entries and the ledger and has two
modes; neither writes to the repo.

**Titles.** An entry is a line starting `- **` or a `## ` heading. A bullet's title is the text after the `- **` up to the next
`**` outside backticks, so a title may hold a quoted `` `**` ``. When the closing `**` isn't on the line, the title continues on
the following lines, each trimmed and joined with a single space; a blank line, a heading or the next `- ` line ends an entry
that never closed (it has no title). A heading's title is its text with the whitespace around it trimmed. A `##` heading whose
section (up to the next `#` or `##` heading) holds a `- **` entry is a group header and no entry; `#` and `###` and deeper
headings never are. Titles are compared as exact strings. A file that has list items (`- `, `* `, `+ `, `1. `) or headings of
level 2 or deeper but yields no title is in a format the parser doesn't read (claude-ship #325), and counts as such, not as empty.

**Ledger.** The `# pitfall: <title> -> <outcome>` lines (from column 0, with something after the `->`) of two files, whose union
counts: the checkout's `.github/claude-ship/lint` and the default branch's. The default branch is found as `lint.sh` finds it,
without the network: `origin/HEAD`, `origin/main`, `origin/master`, then `HEAD`. A ledger line counts whether only the checkout has it (a lint branch in progress) or only the default branch has it (merged,
while the checkout is older). A ledger line for an entry that no longer exists is ignored. The matching is a prefix test on
`# pitfall: <title> -> ` (not a split of the line), so a title that holds ` -> ` is no problem.

**`pending [<dir>]`** prints the titles of `<dir>`'s repository (default: the current directory; outside git, `<dir>` itself)
that no ledger line names, one per line: the queue of a backfill. No `docs/pitfalls.md`, or one with a title and an intro only, prints nothing. Exit 0; 3 with
`pitfall-lint: docs/pitfalls.md has content but no entries this parser reads` on stderr when the file is in a format it doesn't
read (see Titles); 2 when it can't read a file or git (a message on stderr), or on a usage error.

**`hook`** is the `PostToolUse` hook for `Write|Edit|MultiEdit` (`settings/claude-ship.json`, no `onFailure`; the settings are
managed, so it runs on every edit in every repo). Hooks can't start agents, so it can only ask, as
`orchestrate-hint.sh` does. The order matters for cost: the first stage is one `jq` call and a path test, with no git or gh;
the `file_path` must end in `docs/pitfalls.md` (relative to the payload's `cwd` when not absolute) and, after one
`git rev-parse --show-toplevel`, resolve (symlinks included) to `<toplevel>/docs/pitfalls.md`. Every other edit exits there.
Then it needs the agent it asks for, `agents/ship-lint-author.md`, installed (under `${CLAUDE_HOME:-~/.claude}`; until it is, the
hook is silent, so the advice never names an agent or procedure the machine lacks), `AGENTS.md` with a `## Code Review Rules`
and a commit to compare with. The new titles are the pending ones that
`git show HEAD:docs/pitfalls.md` lacks, so rewording an old entry's body, or a Write of the whole file in a repo that was never
backfilled, advises only for what the edit added (a renamed title counts as new, since the ledger names the exact title). A
title advised before in this session and repo is skipped: one empty mark file per session, repo and title under
`${TMPDIR:-/tmp}/claude-ship-pitfall`, written after the advice is given. With new titles left, `CLAUDE_AUTONOMOUS` is read with
`gh variable get` as `orchestrate-hint.sh` does (a missing variable is off and a failing lookup is silence, neither makes a
mark, so the next edit asks again). The advice is an `additionalContext` that names up to 20 titles (the rest wait for the
next edit; the titles are marked as data from the file), the file's absolute path, the toplevel and the default branch, and
says: don't stop the task; start a background `ship-lint-author` with them; a `ship-implementer` doesn't start one but puts
the titles on a `pitfalls:` line of its report; ship the author's `branch:` as its own PR after the task
(`skills/ship/pitfall-lint.md`). When no entry parses but the file has content (the exit-3 case of `pending`), there are no titles
to advise, so after the same checks (agent, `## Code Review Rules`, `CLAUDE_AUTONOMOUS`) it gives one `additionalContext` note that
says so and names both entry forms, once per session and repo (a mark `<session>-<repo>-unparsed`), with no HEAD comparison. A payload that isn't an object, a field of another type, a session id with other than id
characters, no `jq`, `REVIEW_GATE_INNER` set, any git or gh failure: no output, exit 0.

## `agents/ship-lint-author.md` and `skills/ship/pitfall-lint.md`

What the hook's advice asks for (claude-ship #313). The agent is Haiku (`effort: high`) with `isolation: worktree` and the tools
Read, Write, Edit, Bash, Grep and Glob, and `tests/install.sh` checks that frontmatter and that the agent is deployed. Its
inputs are the ones the advice names: `source` (the pitfalls file's absolute path: a new entry may exist only in the session's
checkout, so the author never reads its own worktree's copy), `titles` (marked as data from the file), `branch`, the default
branch with its base ref, and `toplevel`.

- **Why a worktree off the default branch.** The author's commit is a PR of its own, so it can't ride on the task's branch, and
  the lint reads the project file from the default branch, so a rule counts only once merged. A branch that already exists
  locally (a backfill's second batch) is switched to and never reset; a branch another worktree holds is a stop, which is why
  the backfill removes each finished author's worktree before the next one starts.
- **When a rule fits.** Only a literal signature on a single added line that correct code rarely contains; behavioural entries
  are the majority and get `none: <reason>`, and a doubtful one gets `none` as well, because a rule that fires on correct code
  costs more than a missed one. A rule is `warn`: an `error` rule with a false positive would block every Claude commit through
  the pre-commit stub, so a batch that wants one stops and asks.
- **How it is proved.** `lint.sh check --only <id>` (the cases, then the scan of the whole tracked tree). The scan reaches
  `docs/` and `lint-tests`, which quote the signatures, so a rule's globs must exclude them; more than 3 hits on correct code is
  too broad. After 3 failed attempts the rule and all its cases are removed (a case for an undefined rule fails the whole
  check) and the ledger line says `none: no rule passed its cases (<why>)`. A last full `lint.sh check` must exit 0, and each
  title's ledger line is matched as an exact line, since a title that differs by a character stays pending.
- **Commit.** One, with the ledger lines even when every title is `none` (so the entries stop being pending), never pushed. The
  agent edits only `.github/claude-ship/lint` and `.github/claude-ship/lint-tests`.
- **Who starts it.** The session that got the hook's advice, in the background, and ships the branch after its task; an
  orchestrated `ship-implementer` reports a `pitfalls:` line instead and the orchestrator starts the author and queues its
  branch as a trivial unit (`orchestrate.md` step 4). The backfill (`pitfall-lint.md`) runs authors one after the other, 8
  titles each, on `lint/pitfall-backfill`, until `pitfall-lint.sh pending` prints nothing.

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
- **Denies what it can't read; can't deny when it doesn't run.** Input that isn't JSON, has no string
  `tool_input.command`, or is empty denies. A hook that fails to run at all (missing, not executable: exit 126 or
  127) is a non-blocking error, and the agent's Bash then runs unrestricted. Claude Code's docs show `onFailure:
  block` only for settings-style hook entries; subagent frontmatter isn't documented to take it, so the agents
  don't rely on it. `install.sh` checks instead that every hook an agent's frontmatter names is deployed and
  executable, and exits 1 otherwise (#122). The hook does
  not stop `git diff` using a `diff.external` driver from the repo's own config, which a branch can't set. Like the
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
  <sha>`, `[CODEX_WAIT_SECS=<n>] codex-wait.sh <pr> [owner/repo]`, `codex-findings.sh <pr> [owner/repo]`, `[CI_WAIT_POLLS=<1-10>] ci-failures.sh <pr> [owner/repo [--wait]]`, `codex-triage.sh <pr> <file> [owner/repo]`, and
  `gh pr view|checks <pr> ...`. The repository is optional on the wait, findings and triage commands because the agent
  can't `cd` and so may run in any checkout of the repo: it passes the slug to every script so none reads the cwd
  (claude-ship #140). Each takes at most that one slug, checked like the others, and nothing else. `--wait` is the one option `ci-failures.sh` takes, and only as its third word,
  after the repository (`ci-failures.sh 12 --wait` and `ci-failures.sh 12 o/r --wait extra` deny). `<pr>` is up to nine digits, a slug is `owner/repo` of letters, digits and `_.-` only,
  with no part starting with `-`, no part that is `.`, and no `..` anywhere, a sha is 40 lowercase hex characters. Nothing else may precede or follow: any other variable
  (`PATH=`, `GH_TOKEN=`, `CODEX_REQUEST_TRIES=`) denies, `CODEX_WAIT_SECS` only before the wait, and `CI_WAIT_POLLS`
  (1 to 10, no leading zero: 10 polls fit the 10-minute Bash timeout) only before `ci-failures.sh`; only one of the
  two may be given.
- **A poll is denied with a hint.** The agent runs `CODEX_WAIT_SECS=300 codex-wait.sh <pr> <slug>` in the foreground,
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
  the call goes on to the normal permission check, which is not an allow. The deployed mode is tested, and
  `install.sh` exits 1 when a hook an agent names isn't deployed and executable (#122).
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

## `hooks/git-hook.sh` and `hooks/gate-common.sh`

`git-hook.sh <hook name> [git's arguments]` is what each stub in `~/.claude/git-hooks` runs. It chains to the repo's
own hook of that name (`install.sh` sets `core.hooksPath`, which stops git from running `.git/hooks`), and `pre-push`
checks Claude's pushes first; the design is in [`gate.md`](gate.md#pre-push-check). `pre-commit` runs `lint.sh staged
--remote` on Claude's commits first and chains to the repo's own hook only after a clean lint. Who counts as Claude is one
function (`is_claude`: `CLAUDE_CODE_CHILD_SESSION=1` or a `claude` ancestor), shared by both hooks. An error-level hit
(exit 1) refuses the commit with the hits, the way out and `claude-ship: commit refused:`; warnings print and the commit
goes on. It fails closed: `lint.sh` missing, or any exit but 0 and 1 (2 is "couldn't lint"), refuses with the install
hint. During a merge, cherry-pick or revert (`MERGE_HEAD`, `CHERRY_PICK_HEAD` or `REVERT_HEAD` exists) it passes
`--only conflict-marker`, since the index then holds the other side's code, which isn't Claude's. `git commit -a` and
`git commit <path>` work because the lint diffs the index git gives the hook (`GIT_INDEX_FILE`). It exits 1 to refuse
(git then aborts the push or commit; 2 is a usage error, no hook name). It saves git's stdin to a temp file so
the repo's own `pre-push` gets the same lines, and removes it on exit. `tests/git-hook.sh` runs it through real pushes
to bare repos (and Claude's commits, in real repos with the stub `gh` answering the project-file read), with a stub `gh`
and a stub `ps` for the process tree.

`gate-common.sh` holds the two helpers the gate and the hook share, `autonomous` and `github_slugs`. It is sourced,
never run. `autonomous` fails when `gh` is missing: the shell's `gh: not found` would otherwise match the "not found"
that means a repo never opted in.

## `hooks/lint.sh`

The hygiene linter for added lines (README › Hygiene lint). POSIX `sh` plus one awk program, run with `LC_ALL=C`, and
no GNU awk features (`tests/lint.sh` runs one scenario under gawk, mawk and busybox awk). `hooks/lint-rules` holds the
built-in defaults and the grammar reference. The design choices:

- **Added lines only.** The input is `git diff -U0 --inter-hunk-context=0 --diff-filter=ACMRT --no-renames`, with the options that fix its
  shape whatever the user's git config says (`a/` `b/` prefixes, no textconv, external diff, relative paths, context
  between hunks or submodule lines). Line numbers come from the `@@ … +c,d @@` headers, and the counts decide where a hunk ends, so an
  added line that reads `+++ b/x` or `@@` is content. Existing code never fails a commit, so a rule can be adopted
  without a cleanup; renames count as adds (`--no-renames`), so a moved file is linted whole. Binary files have no
  hunks, and deleted files are filtered out.
- **The default branch's project file.** The project layer is read with `git show` from `origin/HEAD` (else
  `origin/main`, `origin/master`, `HEAD`), not from the checkout: a branch that edits `.github/claude-ship/lint` changes
  nothing until it is merged. The refs are local (no network call), so a stale fetch lints with the old file; the
  last fallback, `HEAD`, only applies to a repo with no remote branch. Outside git there is no project layer, and
  `rules` still works.
- **`staged --remote` reads the project file from GitHub.** Local refs are state the agent controls (`git remote set-head`
  or `update-ref` can point the read at the branch itself; docs/pitfalls.md › Local refs), so the pre-commit stub asks
  GitHub: the slug comes from `remote.origin.url` as configured (else with `insteadOf` applied), read by `github_slugs`, and
  the file from `gh api -i repos/<slug>/contents/.github/claude-ship/lint` with the raw media type and no `?ref`, so GitHub
  serves the default branch (as `hooks/p3-issue.sh` reads its label map). The status is the response's own status line, and
  a 200 counts only if `gh` exited 0 too. A 200 is the project layer, a 404 means there is none; anything else for a GitHub origin
  (no `gh`, offline, a 5xx, a body cut short, a 20 s timeout, a URL that can't be read) falls back to the local ref order
  with one note on stderr, `lint: project rules read from <ref>, not GitHub: <why>`. A repo with no origin, or one that isn't
  on GitHub, has nothing to read: `remote_layer` reads the origin first and the same fallback runs with no note (it refuses
  nothing, so staying quiet gives up no protection). A hygiene lint must not block commits offline, and the
  pre-push gate is still the boundary. Limits: `origin`'s URL is itself config the agent can change, which is outside the
  gate's scope (AGENTS.md › Gate scope).
- **`check` reads the checkout, and only to test.** It is the one mode whose project layer is `.github/claude-ship/lint` of
  the working tree (found with `git rev-parse --show-toplevel`, so a subdirectory works), because its job is to try a
  candidate rule before the rule is merged. It never reads the default branch or GitHub, and it changes nothing for
  `staged`, `diff` or `hook`, which keep the invariant that a branch can't weaken its own lint. Layers 1 and 2 are
  the same. It runs awk twice. The first run (`LINT_MODE=cases`) reads `lint-tests` twice in place of a diff, as the
  two passes of a diff: `caseline` turns each `hit|miss <rule> <path> <text>` line into the synthetic `-U0` diff
  `+++ b/<path>`, `@@ -0,0 +1 @@`, `+<text>` and feeds it to `difline`, so `begin_file`,
  `added` and `hit` (globs, `skip`, comment detection, the `unless` of a ban) are the code a commit goes through.
  `hit()` records that the rule reported on the case instead of printing. Each case is a file of its own, at line 1 (so a
  leading byte order mark is ordinary wherever the case sits in `lint-tests`) and keyed by its count in the pass, not by
  its line in `lint-tests`: the opener of one case doesn't make the next `=======` a marker (`openkey`). A case that never reached the rules (its path is under
  a `skip`) is unrunnable and fails, not passes. The second run (`LINT_MODE=check`) lints `git diff -U0` of the empty
  tree against the working tree (no second ref), so every line of every tracked file is added: untracked files aren't
  scanned, binary files have no `+` lines, and an empty repo has nothing to scan (`scan: no hits`; the cases still run, so
  the empty-diff early exit of the other modes doesn't apply). Scan hits are counted per rule but never fail the exit;
  a case failure, a malformed case, a case for an undefined rule, a malformed config line (the cases run stays quiet
  about it, so the note prints once) or an `--only` that names no defined rule does. `--only` filters the cases and
  the hits alike.
- **`staged --only <rule>`** reports one rule and ignores the rest, in the hits, the summary and the exit status. The
  merge case of the pre-commit stub uses it for `conflict-marker`.
- **Bad lines are skipped, git and awk failures are not.** A config typo prints a warning and the rest still applies,
  because one bad line shouldn't lock every repo. A failed `git diff`, an unreadable layer file or an awk crash exits 2,
  so the callers (Claude's commit check) refuse rather than pass unlinted code. Each ban's EREs are checked with
  `grep -E` before awk sees them, since an invalid regex is fatal to awk (one `grep` for all of them, then one each
  to find the bad ones); an invalid one is reported and its line skipped.
- **Globs are `case` patterns.** awk has no `case`, so a glob is turned into an anchored ERE (`*` to `.*`, `?`, `[…]`
  with `[!…]` negation, `\` escapes); the result matches what `case` does under `set -f`.
- **awk finishes by writing a status file**, not an exit code: busybox awk exits 1 on its own errors, which would read as
  an error-level hit.
- **conflict-marker reads the diff twice** (`diff` and a copy): the first pass notes which files add a `<<<<<<<` (with
  or without git's label, and a bare one is a hit too), so the second can report a bare `=======` in order, without
  buffering hits.
- **invisible-char finds UTF-8 byte sequences** (U+200B–200F, 202A–202E, 2060–2064, 2066–2069, FEFF) with `index()` on
  octal-escaped literals, so no awk's regex dialect or locale matters. A byte order mark at the start of the file's
  first line is ordinary. Hits print with control characters replaced by `?` (in the path as well as the line, a tab
  aside), so an added escape sequence or a newline in a file name can't act on the terminal or forge a hit line.
- **Comment text is approximate.** The leader comes from the extension (`#`, `//` plus `/*` block lines, `--`); a line is
  a comment if it starts with the leader or has the leader after whitespace, which a string literal can fool. It is
  enough for rules like "no TODO without an issue", and a rule that needs more can match the whole line.
- **`hook` is the PostToolUse entry point, and never fails.** It reads the tool call from stdin with `jq`
  (`tool_input.file_path`, resolved against `cwd`; the new text is `content`, `new_string` or each `edits[].new_string`, read
  defensively because MultiEdit's shape isn't in Claude Code's docs), changes into the file's directory (so the file's
  repository gives the project layer, not the session's), and builds a synthetic diff of only the candidate lines, one
  hunk per line, which the same awk program lints as it lints any diff. In a repo the candidates are the added lines of
  `git diff -U0 HEAD -- <file>` that contain the new text: the diff keeps earlier uncommitted edits' lines out, the
  text filter keeps lines this edit didn't write out (an edit elsewhere in the file), and a `new_string` that repeats an
  earlier line reports it again, on purpose. An edit may change only part of a line, so a one-line `new_string` matches
  a line that contains it, and a several-line one matches by its first line (the end of a line), middle lines (whole
  lines) and last line (the start of a line); the whole line is then linted. That matching is the fallback (#289): when
  the payload's `tool_response.structuredPatch` is a well-formed, non-empty array of hunks (`newStart` an integer >= 0,
  `lines` strings) and each hunk writes a non-empty `+` line, the candidates are exactly those `+` lines at their numbers
  (a ` ` or `-` line moves the number as in a unified diff; a `\` line is skipped), and they replace the diff and the
  text filter, so a short `new_string` can't match an earlier line. Each line is checked against the file on disk first;
  one that differs (the file changed since, or another numbering) drops the patch for the whole call. A pure-deletion hunk
  falls back too (below). The staged and `--remote` paths never read the payload. A `new_string` with no text in it (a
  deletion) can expose a violation anywhere, so every line the diff adds (outside git, every line) is a candidate then;
  that may report an earlier uncommitted line again, which the pre-commit check would refuse anyway. Untracked files (not gitignored: an ignored file is never committed, so it
  isn't linted), a repo with no commit and files outside git are linted whole; outside git an edit keeps only the
  `new_string` lines that `old_string` lacks. awk writes errors and warnings to two files, and the shell turns them into
  `{"decision":"block","reason":"<errors>\nFix these now: …"}` (warnings ride along in `hookSpecificOutput.additionalContext`)
  or `additionalContext` alone; a clean edit prints nothing. Every failure (no `jq`, bad JSON, a missing layer file, git or awk
  failing) becomes an `additionalContext` note and exit 0, because PostToolUse can't undo the write and a hook that exits
  non-zero would only be noise. The `settings/claude-ship.json` entry has no `onFailure` for the same reason. Reviewer
  sessions have no Write, Edit or MultiEdit (`--tools Read,Grep,Glob`), so the hook never fires there.

## `install.sh`

Only `origin/main` is deployed, so what runs has passed review. That holds for the installer too: after
fetching, it runs main's copy of itself, so a checkout behind main still deploys what main's installer knows to
(#20). The gate's hook entry lives in `~/.claude/settings.json` (see the README).

After deploying, it reads that file (never writes it; only the user edits the settings that register the gate) and
compares the gate's entry with the README snippet from `origin/main`, so the expected values have one source. A
`matcher`, `timeout` below the README's or `onFailure` other than `"block"` that differs gets a warning (exit 0)
and the README's entry to paste. It exits 1 when the gate isn't registered at all (no file, invalid JSON, no
`PreToolUse` hook running `~/.claude/hooks/review-gate.sh` or the absolute path in the target directory) or when
it can't check (no `jq`; a README without the snippets, which would be a bug here). It judges every hook that runs
the gate, not the first (#153): Claude Code runs all of them, so a stale entry still runs with its weaker settings.
More than one gives a warning that the gate is registered N times, then the usual warnings for each one that
differs, named 1st, 2nd, and so on; "The gate is registered" prints only for exactly one hook with no warnings. The orchestrate hint hook is
optional: a missing one only prints an info line. So does a missing `"env": {"CLAUDE_CODE_FORK_SUBAGENT": "0"}`
(only the string `"0"` counts): the PR loop needs it, because under fork mode a subagent's Agent call returns at
once (#160). The same goes for the `PostToolUse` entry (`lint.sh hook` and `pitfall-lint.sh hook`) when the drop-in isn't used: an info
line gives the README's snippet if `settings.json` lacks a hook running either (each is matched from a path separator, so
`pitfall-lint.sh hook` doesn't count as the lint's).

It creates `$dest/claude-ship/lint` (the install's lint rules) with a commented header when it is missing, and never
overwrites it, follows a symlink there or sets the immutable flag on it: it is the user's file. As root under `sudo` the
`claude-ship/` directory and the file it creates go to `SUDO_USER`.

After deploying, it also checks that every hook path named in a deployed ship agent's frontmatter exists and is
executable (`~/.claude/` read as the target directory). A missing one prints `install: <agent> names <path>, which
isn't deployed or isn't executable; its Bash runs unrestricted` and makes the exit 1, because such a hook fails
with a non-blocking error and the agent would run without it (#122).

It also writes the git hook stubs into `$dest/git-hooks` (one per hook git 2.34 runs from the hooks directory except
`push-to-checkout`, `proc-receive` and `fsmonitor-watchman`; each is `#!/bin/sh` and `exec sh '<dest>/hooks/git-hook.sh'
<name> "$@"`, mode 755) and sets git's global `core.hooksPath` to that directory when it is unset or already that path.
Any other value is printed and left alone, and the exit is 1. `$dest` must be an absolute path without a single quote, since
the gate compares the value with `${CLAUDE_HOME:-$HOME/.claude}/git-hooks` as text. The tests give each install its own
`GIT_CONFIG_GLOBAL`.

It also registers the gate in managed settings and locks what it installs (docs/gate.md › Tamper protection). In
order: shfmt (below), then `settings/claude-ship.json` from main's archive is validated with `jq` (a template that isn't one
JSON value holding the gate's `PreToolUse` hook with `timeout` and `onFailure: "block"` exits 1, nothing installed;
an optional `PostToolUse` (the lint's edit hook) is allowed beside it, with a string `command` and a numeric `timeout` and
no `onFailure` requirement, and no other event; without `jq` too), then every installed path that has the immutable flag is lifted with `chattr -i`, recursively for
`skills/ship` and `git-hooks` (an `lsattr` check that a flag is still there stops the install with nothing changed), then the
files are deployed, then the template is copied to `$CLAUDE_SHIP_MANAGED_DIR/managed-settings.d/claude-ship.json` (default
`/etc/claude-code`; skipped with a note when that can't be written, i.e. not root) through a temp file and a `mv`, then the
flags are set again and checked with `lsattr` (a warning naming the paths that lack one, and exit 1 as root;
one warning without `chattr` or `lsattr`). If the script exits early after the lift, an EXIT trap, also run on HUP, INT
and TERM, puts back the flags it recorded before lifting. As root under `sudo`, the directories it creates for the user's
own files (`$dest` itself, `~/.claude` by default, when it is missing, and `agents/`, `skills/` and `claude-ship/`) go to
`SUDO_USER`; `hooks/`, `bin/` and `git-hooks/` stay root's. The registration check accepts the drop-in alone, and when the gate is
in `settings.json` too it says Claude Code runs a handler that appears in both once. Under `sudo` (`SUDO_USER` set) it notes the directory it installs into, since `$HOME` may be root's (`sudo --preserve-env=HOME`, or `CLAUDE_HOME`). The tests put stubs of `chattr`,
`lsattr` and `id` first on `PATH` and point `CLAUDE_SHIP_MANAGED_DIR` into their temp directory; they never touch the real
flags or `/etc`.

Before it changes anything, it runs `scripts/fetch-shfmt.sh` from main's archive into a temp file (starting from the
installed `$dest/bin/shfmt`, so a current one costs no download) and runs that file once with `--version` (#135). A
fetch that fails, or a file that doesn't run, prints `couldn't install shfmt`, exits 1 and deploys nothing, so what
was installed stays as it was: a new gate without shfmt would block every Bash call (#189). Otherwise the verified
file is moved into `$dest/bin/shfmt` along with the rest.

It also removes what main has dropped (#108). `hooks/` and `agents/ship-*.md` are copied file by file, so a hook or ship
agent that main renamed or deleted would stay installed, flagged and selectable. A file is stale when its path
(`hooks/<name>` or `agents/ship-<name>.md`, nothing deeper) is in `origin/main`'s history (`git log --no-renames --name-only`,
so no `diff.renames` setting hides a name), is not in main's tree now, and is a regular file in the target directory (a
symlink or a directory is left alone). Stale files get the same flag lift as the rest and are deleted after the copy
succeeded, one `Removed <path> (no longer in origin/main).` line each; a failed `rm` stops the install. There is no manifest on
purpose: a file the user could edit must not decide what a root install deletes. The history is already read from
`origin/main`, and it errs toward keeping files: a shallow clone, or a path git prints quoted, gives fewer names. If the
`git log` itself fails, nothing is removed and the install warns `couldn't read origin/main's history, so files main has
dropped weren't removed.` (exit unchanged). The user's own files (`hooks/no-attribution.py`, `agents/my-agent.md`, a `ship-`
name main never had) are never touched; one that shares a name main once had would already have been overwritten by an
earlier install.

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
