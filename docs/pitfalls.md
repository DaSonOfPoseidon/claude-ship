# Pitfalls

Classes of bug that reviews have caught here. Check every change against them, and add an entry when a
review finds a new class.

- **Hooks judge a whole command before any of it runs.** A `git commit && git push` chain is reviewed at the
  old HEAD. Commit and push in separate commands.
- **Pattern checks match text, not intent.** The push check also fires on `git push` inside a quoted string,
  and the write check fired on read-only `jq` (removed) and on `>` inside an awk comparison. Test a new
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
  any option or variable you don't explicitly allow.
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
  yours.
- **A status computed from events goes stale when its inputs change some other way.** `codex-review` reruns on
  pushes, reviews and comments, but not when a thread is unresolved, so allowing `unresolveReviewThread` left a
  green status over an open finding (claude-ship #9). Every write a check allows must either trigger it or be
  unable to change what it counts.
- **A hook sees the whole command at once, but each step runs in the state of its own moment.** The gate
  resolved `{owner}/{repo}` in the directory after a trailing `cd`, while the `gh api` before it ran in the
  first one (claude-ship #9). Check each state a step could run in.
