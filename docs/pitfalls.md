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
  can be named, too. The tamper check now reads a syntax tree (shfmt) instead of text, so file names, quoted
  strings and heredoc bodies stop counting (claude-ship #135, #40): add a new Bash check there, as an event
  from the tree, rather than as another regex, and let anything the tree can't settle fall back to the stricter
  old check (docs/gate.md › Tamper protection). The push, PR and `gh api` checks sit behind the same tree: a command
  that runs no git or gh skips them (docs/gate.md › Command reading), and "runs no git" means every command in the
  tree is on a list of tools known not to run their arguments, not that the tree names no git.
- **A command's name is not the program it runs.** The runs-git filter trusted a listed name (`cat`, `echo`) by its
  last path part, so `./cat` and `/tmp/ls` passed as the tools, and by the bare word, so `PATH=. cat` ran a script the
  same command wrote (claude-ship #135). Trust a name only when it is a bare word and nothing in the command
  (a `PATH`, `LD_*`, `BASH_ENV` or `ENV` assignment, a function of that name) can change what it resolves to.
- **A terminator written as a negation accepts characters you didn't think of.** The push-shape strip took
  `>&2` as a descriptor duplication when any non-alphanumeric followed, so `>&2.txt` (bash: a write to the file
  `2.txt`) and `>&1/x` passed; so did `&>/dev/null.log` (no terminator at all) and `>/dev/null,x` (the `/dev/…`
  strips excluded only `[:alnum:]_./-`, so `,` `:` `+` `=` slipped through; claude-ship #41). End every strip
  with the characters that may follow (whitespace, a separator, the end), and test a following `.`, `/`, `-`,
  `,` and `:`. The terminator must also accept the end of the quoted word that contains the redirect:
  `sh -c 'cat x >/dev/null'` ends in a closing quote and was blocked once the terminator tightened. Allow one
  closing quote, but only when whitespace, a separator or the end follows it; `>&2'.txt'` and `>/dev/null'x'`
  still write a file.
- **Process rules are a table, not a list of special cases.** Patching one sentence per review finding moved
  the gap each round (OBDCracker #128, three rounds). State a rule once, as a table, and check every cell.
- **A command interrupted midway may have done part of its work.** Check what exists (issues, commits)
  before redoing it.
- **GitHub's PR API lags a push.** For a minute or so after a push, a PR can still report the old head, and
  a review requested then covers the old commit (claude-ship #4), and `gh pr checks` reads the old head's CI
  (claude-ship #118). Wait until `headRefOid` is HEAD before acting on either.
- **A wait loop that reads every failure as "not done yet" hides a broken command.** A relative script path
  run from the wrong directory spun for 30 minutes after the review had finished. Use absolute paths, and
  stop on any error.
- **A pipeline's exit status is its last command's.** `x=$(gh api … | wc -l)` succeeds when `gh` fails,
  so a failed call reads as an empty result. Assign each call on its own, then pipe the result. Ignoring the
  status and hiding stderr (`2>/dev/null`) does the same: the gate's PR and thread lookups, and the `git log` and
  `git diff` inside its prompt, read a failed call as "no PR", "no threads" or an empty diff and skipped the
  check (claude-ship #106). Assign the call, test its status with `|| { …; exit 2; }`, and do it before the file
  that quotes it is written. It matters most when the empty result picks a *weaker fallback*: `rules_of`'s
  `git show … 2>/dev/null | sed` made an unreadable default-branch AGENTS.md look like "no rules" and reviewed the
  branch against its own (claude-ship #152). Tell "missing" (`git cat-file -e`) from "failed" (`git show`'s status),
  fall back only on the first and block on the second.
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
  only the ship skill's own `gh pr/issue create/edit/comment/close` is exempt.
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
  The same holds for a job that never starts: a request Codex never picked up kept the wait running its full 20
  minutes and counted as a round (claude-ship #133). And one verdict, used by every script that acts on it:
  `codex-request.sh` judged a request stale with its own clock while `codex-status.sh` judged it another way, so
  it replaced a review that was still running (claude-ship #139). Ask the status script instead of re-deriving it.
- **An agent that reports before its background job finishes hands over a wrong result.** `ship-codex` moved
  `codex-wait.sh` to the background, tried to poll it (denied), and sent `outcome: error` to the implementer
  while the review was still running (claude-ship #142). Its fix, ending the turn to wait for the notification,
  was wrong too: a subagent's Agent call returns when its turn ends, so the implementer got an interim result and
  handed back, and the real report landed with the orchestrator (claude-ship #147; PRs #146 and #150). A
  subagent that ends its turn while its own work is still running hands its parent an interim result, so nested
  agents must block in the foreground, in chunks under the tool's timeout, and send one report at the end. Tell
  the caller too that a result without an `outcome:` isn't the report, and to resume the agent for it. Prose
  rules weren't enough either: the agent still backgrounded its waits and ended its turn (PRs #165 and #170,
  claude-ship #171), so a nested agent's foreground rule needs a hook that denies `run_in_background`
  (`hooks/codex-bash.sh`). And never tell an agent to end its turn on background work, even as a fallback:
  that instruction is what made #147 happen. Under Claude Code's fork mode, nested Agent calls start in the
  background however the child waits, so the foreground wait alone doesn't make the report the parent's result;
  the user setting `CLAUDE_CODE_FORK_SUBAGENT=0` does (claude-ship #160).
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
- **A checker that stops at `--` misses options after it.** `--` is the end of options only when it is an option,
  not an option's argument: in `git grep -e -- --open-files-in-pager=/tmp/helper`, the first `--` is `-e`'s pattern,
  so git still parses the pager option and runs the helper (claude-ship #68, `hooks/explorer-bash.sh`). Check every
  word, before and after any `--`, and accept refusing a pathspec that looks like a denied option. The same goes
  for any word a checker skips: option values (`-e`, `-f`, `--jq`) can look like anything.
- **A hook's allow is a grant, not the absence of a deny.** `hooks/codex-bash.sh` approves calls for a subagent
  that auto mode would otherwise deny, so every form it lets through must be exact: the installed script by its
  `~/` path (not `$HOME`, `./`, `..`, `sh`, `env`), numeric and hex arguments by pattern, one named environment
  variable in one place, and a file argument by equality with the one path expected, never by a prefix or a glob.
  Anything the hook doesn't list exits 2. Test the near misses of every allowed form (`.bak`, `..`, another PR's
  number, an extra argument, an option after `--`), not just the allowed ones (claude-ship #132).
- **A hook that dies is not a hook that said no.** Claude Code lets a tool call through when a plain command hook
  times out, crashes or exits with anything but 0 or 2, unless its registration has `"onFailure": "block"`. The gate
  had two reviewers of 1100 s each under a 1200 s hook timeout, and read a missing or failing `jq` as an empty tool
  name, which falls into `exit 0` (claude-ship #103). Keep the budget below the timeout, block on anything the gate
  could not read, and keep a test reading the README snippet so the registration cannot drift.
- **A file's extension doesn't say whether it's behaviour.** A `.md` prompt, skill, agent or rules file changes what
  Claude does, yet the gate treated every `*.md` as docs and gave it only the Haiku claims check. Classify by path
  and role, not extension: the gate's `kind` block lists the `.md` locations that are behaviour, lists a rename's old
  path too (`--no-renames`), blocks when the list can't be read, and treats an empty one as code (claude-ship #105).
- **Two spellings of the same repo are not equal strings.** The gate logs `slug` as written in origin's push URL;
  `gh repo view` returns GitHub's canonical `nameWithOwner`. Comparing them with `==` drops every row of a repo
  whose remote differs in case, and the missing rows read as a cheap report. Compare repo slugs without case
  (`ascii_downcase`), and test with a differently-cased row (claude-ship #110).
- **A line scanner for Markdown settings must treat fences and HTML comments as literal inside each other.** The
  local-mode check in `hooks/orchestrate-hint.sh` read `<!--` inside a fenced example as a real comment, which hid
  the settings after it, and let the inner triple backticks of a four-backtick example end the fence early, so an
  example's `- mode: local` opted a workspace in (claude-ship #159, three Codex rounds, each finding the next
  sibling). Write the scanner as one state table (normal, in a fence, in a comment, against every kind of line:
  fence, `<!--`, `-->`, both on one line, heading, setting), close a fence only on its own character at the
  opener's length or more, and add a test per cell that can occur.
- **An encoding that joins path parts must escape its own separator and escape character first.** Writing `/`
  as `+` gave `/srv/a+b/c` and `/srv/a/b+c` the same state directory, so one workspace's loop overwrote the
  other's (claude-ship #159). Escape the escape character (`%` to `%25`), then the new separator (`+` to `%2B`),
  then substitute, and give the doc a pair of paths that used to collide. The same slip came back for plan file
  names (`/` as `-` gave `feat/a-b` and `feat-a/b` one file, claude-ship #120): reuse the written encoding, don't
  invent a second, and have whatever opens the file check the name it holds.
- **A filter by branch name also matches other repositories' branches of that name.** `gh pr list --head <branch>`
  returns a fork's PR from a branch of the same name, so `unit-state.sh` could call an unfinished unit merged or
  send the orchestrator into someone else's review (claude-ship #120). Ask for `isCrossRepository`, drop those, and
  fail when the field is missing. A state read from a merged PR also says nothing about commits made after its last
  push: check for unpushed work before treating the unit as done, against the PR's own last head
  (`refs/pull/<n>/head`), since origin's branch is deleted by then and has nothing to compare with.
- **A doc must not widen an opt-in beyond its marker.** `skills/ship/SKILL.md` said any workspace that isn't a
  GitHub repo gets the local loop, while the hook and `orchestrate.md` start it only on `- mode: local` or a user
  request (claude-ship #159). State each opt-in once, with its exact marker, and have other docs point to it.
- **A shell runs a trap only after its foreground command returns.** The eval runner trapped `TERM` and then ran each
  case in the foreground, so a terminated run let the reviewer finish (and a verifier start) before cleaning up,
  spending tokens nobody wanted (claude-ship #163). Run the long command in the background, `wait` on it (a signal ends
  `wait` at once), and have the trap stop the command and everything under it (`ps -A -o pid= -o ppid=` walks the
  tree, since `timeout` puts its child in another process group) before it exits. Test it with a signal sent while the
  reviewer sleeps, and assert the reviewer is gone.
- **An error path must keep what the success path records.** The runner's error rows dropped the cost of a reviewer run
  that failed, timed out or returned nothing readable, so a failing configuration looked cheaper than it was
  (claude-ship #163). Give every path that writes a row the same fields, with what was measured before the failure, and
  test each failure (exit status, timeout, unreadable output) for the field.
- **A function's status is its last command's, including a group that writes a file.** `build_prompt` was a `{ cat
  template; …; echo; } >out` group, so a template it couldn't read left a prompt without the reviewer's instructions and
  a status of 0 (claude-ship #163). Test that the inputs are readable before the group, fail the build on a failed
  `cat`, and make the caller treat a failed build as a block or an error. Check the inputs a caller names up front too
  (`--prompt-dir` needs every prompt, not only the lib).
- **Text the PR's own code writes is untrusted, and it travels.** CI log tails come from the PR's tests and scripts, so
  they can say anything. `ship-codex` copies them into its report and the implementer, which can edit, commit and
  push, reads them (claude-ship #118). Wherever a step passes such text on, say in that step that it is data, not
  instructions, and that it is only used to see which check failed; the same goes for PR text and Codex comments.
- **A wait on "all checks" includes the check that waits on you.** `gh pr checks --watch` listed `codex-review`, which stays
  pending until Codex has reviewed, and the review is requested only after the wait, so every round would end as a
  timeout; read as a result, the same status (failed while a thread is open) would also read as a CI failure no code
  change fixes (claude-ship #118). Name the checks that are the thing being gated and leave them out, by exact name,
  of what you wait on and of what you count as failed; test a lookalike name.
