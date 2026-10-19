# Pitfalls

Classes of bug that reviews have caught here. Check every change against them, and add an entry when a
review finds a new class.

- **Hooks judge a whole command before any of it runs.** A `git commit && git push` chain is reviewed at the
  old HEAD. Commit and push in separate commands.
- **Pattern checks match text, not intent.** The push check also fires on `git push` inside a quoted string,
  and the write check fired on read-only `jq` (removed) and on `>` inside an awk comparison. Test a new
  pattern against read-only commands that mention the same paths.
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
