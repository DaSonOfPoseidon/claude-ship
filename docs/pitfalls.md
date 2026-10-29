# Pitfalls

Classes of bug that reviews have caught here. Check every change against them, and add an entry when a
review finds a new class.

- **Hooks judge a whole command before any of it runs.** A `git commit && git push` chain is reviewed at the
  old HEAD. Commit and push in separate commands.
- **Pattern checks match text, not intent.** The push check also fires on `git push` inside a quoted string,
  and the write check fired on read-only `jq` (removed), on `>` inside an awk comparison and on a `2>&1`
  stderr merge (claude-ship #21). A redirect writes only through its target, but a quoted one still writes
  inside `sh -c` or `awk`, so quoting doesn't make it text. Test a new
  pattern against read-only commands that mention the same paths. It cuts both ways: a word boundary that
  excluded `/` missed `/usr/bin/gh api` and `/usr/bin/git push` (claude-ship #9). Test every way the command
  can be named, too.
- **Process rules are a table, not a list of special cases.** Patching one sentence per review finding moved
  the gap each round (OBDCracker #128, three rounds). State a rule once, as a table, and check every cell.
- **A command interrupted midway may have done part of its work.** Check what exists (issues, commits)
  before redoing it.
- **GitHub's PR API lags a push.** For a minute or so after a push, a PR can still report the old head, and
  a review requested then covers the old commit (claude-ship #4). Wait until `headRefOid` is HEAD.
- **A wait loop that reads every failure as "not done yet" hides a broken command.** A relative script path
  run from the wrong directory spun for 30 minutes after the review had finished. Use absolute paths, and
  stop on any error.
- **A pipeline's exit status is its last command's.** `x=$(gh api … | wc -l)` succeeds when `gh` fails,
  so a failed call reads as an empty result. Assign each call on its own, then pipe the result.
- **Options and environment before a subcommand change what it does.** `git -c push.default=matching push`,
  `git --git-dir x push`, `GIT_DIR=x git push` and `env … git push` all push something other than what a check
  of `git push`'s own arguments sees (claude-ship #3, five gate rounds). Check the whole command, and block
  any option or variable you don't explicitly allow. To find a subcommand, skip only the options you know take a
  value: a pattern that lets any option take one read `git --no-pager config` as option `config` (claude-ship
  #14).
- **Shell quoting and expansion hide the real argument from a text check.** `repos/o/r/con''tents`,
  `repos/${OWNER}/${REPO}/git/refs` and `-f query="$(cat q.graphql)"` don't contain the text gh finally sends.
  `git -c "a=b c" push` hid the push itself. Split words with a left-to-right scanner (the gate's is jq) that
  keeps every quoted character distinct; four rounds of sed patches each missed a case (claude-ship #9). Treat
  quoting you can't read as the worst case.
- **A missing argument under `set -u` exits 1, which a caller may read as a result.** `codex-wait.sh` with no
  PR number looked like a 30-minute timeout (claude-ship #8). Check required arguments and exit 2 on misuse.
- **Checking one side of a pair leaves the other open.** The push check read a refspec's source but not its
  destination (`HEAD:refs/tags/x`), and origin's fetch URL but not its push URL (claude-ship #9). Check every
  side git actually uses: `git remote get-url --push --all`, and both ends of a refspec.
- **A list of what's dangerous misses what nobody listed; list what's allowed.** GraphQL mutations name their
  target inside the query and new ones keep appearing, so the gate allows only the mutations the ship skill
  uses instead of blocking known write mutations (claude-ship #9).
- **A parser that returns nothing for input it doesn't recognize fails open.** The gate read
  `https://user@github.com/…`, `ssh://…:2222/…` and `GitHub.com` remotes as "not GitHub" and let the push through
  (claude-ship #9). Parse every form you know, and treat anything that looks like yours but doesn't parse as
  yours. The same went for `gh api -iFref=…` (a short-flag cluster read as one unknown flag; `-hi` too, since `-h` is
  gh's no-argument help flag, so list every flag that takes no value) and for
  `mcp__GitHub__push_files` (a case-sensitive server name) (claude-ship #12, #15).
- **A status computed from events goes stale when its inputs change some other way.** `codex-review` reruns on
  pushes, reviews and comments, but not when a thread is unresolved, so allowing `unresolveReviewThread` left a
  green status over an open finding (claude-ship #9). Every write a check allows must either trigger it or be
  unable to change what it counts. Two writers of one status must also be serialized: splitting the workflow's
  concurrency group so comment runs stop cancelling the push run let a reopened PR's push run read 0 threads and
  write `success` over a comment run's `failure` (claude-ship #75). Keep one group per PR with
  `cancel-in-progress: false`, so the last run to start reads the latest state.
- **A hook sees the whole command at once, but each step runs in the state of its own moment.** The gate
  resolved `{owner}/{repo}` in the directory after a trailing `cd`, while the `gh api` before it ran in the
  first one (claude-ship #9). Check each state a step could run in. State the gate reads up front (git config,
  refs, remotes) is stale once an earlier step writes it, and blocking the known writes can't keep up:
  `git config push.followTags true && git push` (claude-ship #14), then `git show --output=.git/refs/heads/x` and a
  write to any file an `include.path` pulls into the config (claude-ship #25) each passed the previous list. The
  class is "anything that runs before the push in the same command", so a pushing command may contain only the
  push: a leading `cd <dir> &&`, harmless redirects (`2>&1`, `/dev/null`) and trailing pipes into read-only
  filters (`tail`, `head`, `cat`, `grep`). Run everything else in its own command first. A push that only the raw command shows
  (`sh -c "…; git push"`, `eval`) is quoted text to a word scanner but still runs, so it gets the same check;
  only the ship skill's own `gh pr/issue create/edit/comment` is exempt.
- **A permission that looks like it belongs to one step may serve others.** Dropping `actions/checkout` took
  `contents: read` with it, but the status script's activity lookup needed it too (claude-ship #18). Before
  removing a permission, list every API call that runs under the token, and keep each permission they need.
- **Another tool's output can leave out a field you match on.** Codex's summary names the reviewed commit,
  except on some clean reviews, where it shows `—`, and `codex-status.sh` waited forever (claude-ship #30).
  Decide what each missing field means, fail closed, and test the blank case.
- **Anyone can post a comment, and a completion doesn't say which request it answers.** `codex-status.sh`
  counted `@codex review` from any non-bot, so an outsider could reset a success (claude-ship #33). Count
  only OWNER and COLLABORATOR comments (an org MEMBER needn't have access to the repo). The summary's edit
  history and Codex's reactions don't say which request a completion answers. A new request ends any
  review still running on the PR: in all 14 overlaps across three repos, one completion followed
  (claude-ship #61). So a blank-commit row succeeds only when the latest trusted request came after the
  push and exactly one completion marker (receipt comments and Codex reviews, the current one included)
  follows it, and the review finished after it. Pairing every request with its own marker instead left a
  stalled or failed review's request open forever, until someone deleted its comment (claude-ship #33, #61).
  More than one marker after the request means one nobody asked for (an automatic review, claude-ship #49):
  fail closed. Compare timestamps as text, never with GNU-only `date -d`. Don't widen the markers to every
  Codex comment, or an unrelated comment would count as a completion.
- **Local refs are state the agent controls.** The gate diffed against a hardcoded `origin/main`, which
  repos whose default is `master` don't have (claude-ship #51). Reading `origin/HEAD` instead would let
  `git remote set-head` point the base at the branch itself and leave nothing to review. Ask GitHub for
  the default branch, and fetch it with an explicit refspec.
- **Another service's job can die without saying so.** About one Codex review in ten here keeps its 👀 and a
  `running` summary forever, with no review, receipt or error (openai/codex#55890). The ship skill waited 15
  minutes, then forbade a retry, so every stall needed the user (claude-ship #61). Bound the wait by the
  job's own last update, not by a total time, retry once, and don't charge a round for a job that never ran.
- **A new script is committed without its execute bit.** Written with an editor, it lands as `100644`, and
  `install.sh` copies modes as they are, so a hook registered as a command fails with `Permission denied`
  while tests that run it with `sh` pass (claude-ship #69). Commit scripts as `100755`
  (`git update-index --chmod=+x`), and test the deployed mode, not just the behaviour.
- **A step that reads the current checkout assumes it's the PR's.** `gh pr` without a number acts on the
  current branch's PR, and `codex-request.sh` and the ship skill's status check compare against local HEAD.
  An orchestrator whose implementer pushed from another worktree would merge the wrong PR, reject a valid
  review, or never get a request posted. And a new agent that reset its branch to origin's would drop an
  earlier agent's unpushed commits (claude-ship #69). Name the PR, compare against the PR's head, run
  HEAD-based scripts from the worktree that pushed, and start from the local branch when it has commits.
- **A doc of an allowlist can read backwards.** `docs/gate.md` said options "outside the allowed list" block and then
  listed the allowed ones (claude-ship #29). Say which side the list is ("only these pass; any other blocks") and
  check each list against the code it describes.
