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
