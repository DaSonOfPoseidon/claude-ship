# The pre-push review gate: design notes

`hooks/review-gate.sh` is a PreToolUse hook. It blocks `git push` and `gh pr create` until an independent
reviewer (a fresh headless Claude session with no context from the current one) has reviewed the branch diff
against the repo's default branch. The script keeps only short comments on its checks and regexes; the reasons
behind them are here. Classes of bug past reviews caught are in [`pitfalls.md`](pitfalls.md).

The gate catches Claude's own slips; it isn't a security boundary. It judges command text, and its state is
writable by any shell. Branch protection requiring the `codex-review` status is the server-side backstop.

Exit 0 allows the tool call; exit 2 blocks it and shows stderr to Claude.

## Opt-in

The gate runs only in GitHub repos whose variable `CLAUDE_AUTONOMOUS` is `true`:

```sh
gh variable set CLAUDE_AUTONOMOUS --body true -R <owner/repo>
```

It then needs the repo's rules in `AGENTS.md` › `## Code Review Rules` (the `ship` skill's bootstrap writes
them). Codex reads the same section, so both reviewers judge by the same rules and the same P0–P3 scale.

The reviewer's own sessions load the hooks too; `REVIEW_GATE_INNER=1` makes the gate exit at once there, so it
never recurses.

**Registration must say `"onFailure": "block"`** (README › Install; Claude Code 2.1.295 or later). A plain command
hook that times out, crashes or exits with anything but 0 or 2 lets the tool call through, so without it a slow
review or a dying gate means an unreviewed push. The hook's `timeout` (2400 s) must also exceed the reviewer budget
(see Reviewer pipeline), or the budget guards nothing; `tests/gate-readme.sh` checks both against the README's
snippet. The gate needs `jq`: without it, or when jq can't read the tool call, the gate blocks every call it sees
(Bash, file writes, MCP) rather than reading the call as nothing, since it couldn't tell what the call was.
That holds in every repo, opted in or not, because the jq check comes before any opt-in check. With jq working, a
repo that isn't opted in, a directory that isn't a git repo and a repo with no GitHub remote still pass, as before,
except that every Bash call also needs shfmt and a command it can parse (Tamper protection).

The default branch comes from GitHub (`gh repo view`), not from a local `origin/HEAD`: that is state an agent
can point at its own branch, which would leave nothing to review. When GitHub can't say, the gate blocks.

## Command reading

The gate reads the command two ways: the raw text, and a list of words as the shell would split them
(`shell_words`, run by jq). Quotes and backslashes go, and every character they made literal becomes a marker,
so `git -c "a=b c" push` and `git "push"` read as the push they are and a quoted `;` can't pass for a separator.

| Marker | Stands for |
|---|---|
| `@SP@` | space or tab |
| `@NL@` | newline |
| `@OP@` | `;`, `&`, `\|`, `<` or `>` |
| `@LP@`, `@RP@` | `(`, `)` |
| `@DL@` | `$` |
| `@BQ@` | a backtick |
| `@DQ@`, `@SQ@` | `"`, `'` |
| `@UQ@` | quoting the scanner can't read (unterminated, or bash's `$'...'`) |

Inside double quotes `$` and backticks still expand, so they stay as they are. Pushes are looked for in both
forms, and every form that shows one must pass the checks. Checks that read text rather than structure see both
the raw command and its unmarked words (`cmd_all`), so quoting (`CLAUDE_AUTONO''MOUS`, `c''d`) can't split a
name apart.

The tamper check, and the filter below, read a third form: the syntax tree shfmt makes of the command, where a quoted
string, a file name and a heredoc body are what they are instead of text that looks like a command (Tamper
protection below). The command must parse, or the call blocks.

**The filter (`runs_gitgh`).** The checks that read text (the quoting check, the `gh api` scan, the push and
`gh pr create` checks) only matter for a command that runs git or gh, so the tree decides first. The tamper walk
(same jq run, same wrappers, `sh -c` and `eval` strings parsed again to depth 3) also raises `gg` for a command
whose effective word is `git` or `gh` (also by path: `/usr/bin/git`), and `ggdyn` for anything that might run one.
With neither, the command is not a push, a PR create or a `gh api` call, so after the tamper, waiver and opt-in
checks the gate exits 0 without the rest: a heredoc body, a quoted argument or an `echo` that merely mentions
`git push`, `gh pr create` or `gh api -X DELETE …` no longer blocks or starts a review (#135). With `gg` or `ggdyn`
everything runs exactly as before, text checks included, so a real `gh issue comment … <<EOF` keeps its quoting check.

What is `ggdyn`: the filter lists what is known *not* to run its arguments (`ggsafe`: `cat`, `echo`, `printf`, `grep`,
`rg`, `wc`, `head`, `tail`, `sort`, `tee`, `ls`, `jq`, `mkdir`, `cp`, `mv`, `rm`, `cd`, …; not `sed` or `awk`, which can
run commands) and treats every other effective command as unknown, so a wrapper the gate doesn't list (`flock`, `watch`,
`ssh`, `busybox`), an interpreter (`python3 -c`, `node`), a script (`./run.sh`, `make`) or a shell function that calls one
can't hide a push. Also unknown:

- a word that is a path ending in the name of a listed tool, a wrapper or a shell (`./cat`, `/tmp/env`, `/bin/cat`): a
  script of that name may be anything (only `git` and `gh` by path count as themselves);
- a dynamic command word (`$x push`, `$(echo git) push`, `$'…'`); a dynamic argument is fine only for a listed tool
  (`cat "$f"`);
- a wrapper it can't unwrap, a shell run without `-c` (stdin, a script, `bash -s`, `bash <<EOF`), `source`, `.`, and an
  `sh -c` or `eval` string that is dynamic, doesn't parse or nests deeper than 3;
- text that bash itself runs: `${!x}` and `${x@P}`, arithmetic over a variable (`$((x))`, `(( ))`, `let`, `[[ a -eq b ]]`,
  `[[ -v x ]]`), an array subscript, and the options that make a listed tool run something (`printf -v`, `rg --pre`,
  `sort --compress-program`).

Function bodies, `$(…)` and backticks, process substitutions and the `$(…)` in an unquoted heredoc are all in the tree,
so `f(){ git push; }; f` and `cat <<EOF` with `$(git push)` are `gg`; a quoted heredoc body is data. A pipe or a
heredoc feeding an unlisted command is no exception: that command is unknown on its own.
A script written in one command and run by the same command (`./x`, `sh x`) is unknown too, since what runs isn't
listed; one call that writes it and a later call that runs it are two calls, each judged on its own.

A command that already holds a marker, quoting the scanner can't read, or a push whose own words have literal
separators, quotes, `$` or newlines can't be checked word by word, so it blocks.

`git` and `gh` may be named by a path (`/usr/bin/git`, `./gh`), so `/` counts as a word boundary before them;
`.`, `_` and `-` don't (`.git/`, `my-gh`). Any global options, each with at most one value word, may come
between `git` and the subcommand, so `git --git-dir x push` still counts as a push; `push_scope` then allows
only `-C`.

## Push shape

The review covers HEAD, so a push may send only HEAD, to origin, and only when every origin URL (fetch and
push) is the same GitHub repo. Git fetches from the first URL and pushes to all of them, and `github_slugs`
drops URLs that aren't GitHub's, so a local path among them would go unseen. The review diffs against the
default branch and reads its rules through origin's fetch URL, so that must be the repo the push lands in.

`github_slugs` reads any scheme, user and port, any host case, GitHub's ssh-over-443 host, and a
fully-qualified host's trailing dot (`github.com.`). A URL whose host is github.com (or under it) but doesn't
parse prints as `?<url>`, and callers fail closed on it. Other hosts and local paths aren't GitHub.

Only these push options pass: `-u`, `--set-upstream`, `-f`, `--force`, `--force-with-lease*`,
`--force-if-includes`, `-q`, `-v`, `-n`, `--dry-run`, `--no-verify`, `--progress`, `--atomic`. Any other option
blocks, since some (`--all`, `--mirror`, `--tags`, `--delete`) send other refs. A refspec's destination is checked as well as its source: `HEAD:other` or `HEAD:refs/tags/x` writes a ref
the review didn't cover. Config that changes what a bare push sends blocks too: `push.default` `matching`, or
`upstream`/`tracking` when the branch tracks another one; `remote.origin.push`; `push.followTags`;
`push.recurseSubmodules` `on-demand` or `only`; `remote.origin.mirror`.

Git global options other than `-C` (`-c push.default=matching`, `--git-dir`, ...) can change what's pushed or
from which repo, and block. Environment overrides never get that far: only the push may run. The `sed` that reads
the global options sees one `git … push`, so the check for `-c`, `--git-dir` and the like also runs over the
whole command, and so does the check for a single `-C` (the directory check follows only one).

**What may run next to the push.** The checks read git config, refs and files before the command runs, so
anything earlier in the command (or a later step that reruns it) can change what the push sends after they
passed: `git show --output=…`, or `printf … > /tmp/settings` behind an `include.path`. So a pushing command holds
only:

- the push,
- at most one leading `cd <dir> &&`,
- harmless redirects (a whole descriptor duplication, `/dev/null`, `/dev/stdout` or `/dev/stderr`, each followed by
  whitespace, a separator or the end, so `>&2.txt` and `&>/dev/null.log` are file writes and block), and
- trailing pipes into read-only filters (`tail`, `head`, `cat`, `grep`).

Redirects are taken out first, then every simple command (split at `;&|()` and newlines) must be one of those.
Shell syntax the split can't place (substitutions, a trailing `&`, a redirect, a second line, a `;` before the
push) fails the whole-command `shape` regex.

A push shown only by the raw command is usually quoted text, but `sh -c "…; git push"` and `eval` run it, so it
is judged too. The one exception is the ship skill's own `gh pr/issue create/edit/comment/close`, whose quoted
words are data: it has to be that single command, with no unquoted separator, redirect or expansion. Such a
command (`data_only`) skips `push_scope` entirely, so a body that mentions `git push` any number of times, with
any text after it (`` `git push origin HEAD` exits 2 ``), is not read as a push (#56). It also skips the HEAD
review (the dirty-tree and `.pass` checks and the reviewers): nothing is pushed, so the gate exits 0 right after
`push_scope`, whether or not HEAD has a pass (#91). `gh pr create` is the exception: it is gated like a push, so
it still needs a passing review of HEAD. Anything outside that shape
(`FOO=1 gh …`, `gh -R o/r issue …`, a second line, `&& git push`) isn't `data_only` and is judged as before.
`gh pr merge` isn't in the list. A backtick inside single quotes is data (the word scanner marks it `@BQ@`);
inside double quotes it is a command substitution, so that body isn't `data_only` and is judged as a push.

> Known gap, reported with #29: the exception's code (`data_only`) rejects command substitution (`$(`, `$[` and
> backticks) but not a bare unquoted `$VAR`. The variable is only data to `gh`, so nothing runs, but "expansion"
> overstated what the check does.

Where the command runs: the session's directory, then a `cd <dir>` in the command, then `git -C <dir>`. More
than one `cd`, or one the gate can't follow (`~`, `-`, `$`, a backtick), blocks rather than guessing which
branch is pushed. `cd`s are counted in both command forms, so a quoted-apart `c''d` counts; the target is read
from the raw command, and one only the words show can't be read there, so it blocks. A later `git -C` replaces
the directory, but other calls in the command still run in the `cd` target. The `-C` directory is the whole word
after `-C`, so `-C "/a)b"` can't read as `/a`; two different `-C` directories in the raw and word forms block.

## MCP writes

The matcher sends the GitHub MCP tools that write code or PRs (`push_files`, `create_or_update_file`,
`delete_file`, `create_branch`, `create_pull_request`, `update_pull_request`, `update_pull_request_branch`,
`merge_pull_request`) to the gate by tool name, so the server may be called anything (`github`, `GitHub`, `gh`).
A call that names neither an owner nor a repo isn't GitHub's, since its tools need both, and passes. In an
opted-in repo the call blocks; if the opt-in can't be read, it blocks too.

## REST allowlist

In an opted-in repo, `gh api` writes pass only if the ship skill makes them: comments, replies, reviews,
reactions, issues, labels, issue dependency links (`blocked_by`), workflow dispatches, and its GraphQL
mutations. Anything else (commits, refs, PRs, statuses, checks, settings, Actions variables like
`CLAUDE_AUTONOMOUS`) could land code or change what guards it without a review, so it blocks.

`api_scan` reads each call word by word from the word form. A call writes when its method isn't GET (or HEAD),
and gh's default method is POST once it has fields or an `--input`. It prints nothing (no such write),
`block <why>`, or `repo <owner/repo>` (`{owner}/{repo}` for gh's placeholders, `here` when the endpoint names no
repo), one line per repo it writes to.

- gh reads a short-flag cluster one letter at a time until a flag that takes a value, so `-iFa=b` is
  `-i -Fa=b` and `-iXPOST` is `-i -XPOST`. `-i` and `-h` (help) are the only short flags of `gh api` that take
  none, and `-i=false` and `-h=false` give them one.
- Long options, and short ones with their value attached (`-Haccept:x`), pass. A short cluster the gate can't
  read could hide a field or a method, so it blocks.
- A redirection (`2>/dev/null`, `> out`, `2>&1`) isn't an argument; a bare operator takes the next word.
- More than one endpoint, or an endpoint holding `$`, a backtick, markers or `://`, blocks: the gate can't tell
  which one it writes.
- Endpoints that name no repo (orgs, users, ...) count against the repos where the command runs.
  `repositories/<id>` blocks, since the repo can't be checked.
- One line per simple command (separators split it), each `gh api` call scanned on its own. A segment that ends
  in `$` was cut by an unquoted `$(`, which hides the rest of its words, like a backtick. A `gh api` the raw
  command shows but the word-split form loses can't be scanned, so it blocks.
- gh reads the repo from `GH_REPO`, or from the remotes here; the gate follows only the remotes. `GH_REPO` may
  be quoted apart (`GH_RE''PO`) or inherited, so the word-split form and the environment count too.

**GraphQL** names its target inside the mutation, so only the ship skill's own mutations pass, in any repo:
`resolveReviewThread`, `addPullRequestReviewThreadReply`, `addComment`, `updateIssueComment`,
`addPullRequestReview`, `addPullRequestReviewComment`, `submitPullRequestReview`. `unresolveReviewThread` is not
one: it changes what `codex-status.sh` counts without rerunning it. A query the gate can't read whole (a file,
stdin or a shell expansion) blocks. Strings and comments hold no structure; then top-level fields are names at
brace depth 1, outside arguments, that aren't aliases (`alias: field`). A mutation that uses a fragment blocks,
since the gate doesn't follow fragments.

A write that names a repo is checked for opt-in in each repo it names. `{owner}/{repo}` and `here` are whichever
repo gh picks from the remotes where it runs, so every GitHub remote counts, in the session's directory, the one
a `cd` moves to and a `git -C` one: the call may run before or after either.

## Tamper protection

The installed gate, its prompts and lib (`hooks/`), the ship skill and agents, the gate's state (`.git/review-gate/`),
the settings that register it and shfmt (`~/.claude/bin/`, which the gate reads every Bash command with, so replacing
it would blind the gate) are the user's to change; claude-ship's source changes through reviewed PRs. `Write`,
`Edit`, `MultiEdit` and `NotebookEdit` calls on those paths block. A project's own `.claude/settings` may change,
but not to turn hooks off (`disableAllHooks`).

For Bash, writing gate state or the installed gate would bypass the review; reading its reports is fine. The check
reads the command's syntax tree, not its text, so a protected path in a file name, a quoted string or a heredoc body
isn't a write (#135, #40).

**The parse fails closed.** Before any other check, `~/.claude/bin/shfmt -ln bash --to-json` reads the command.
No shfmt (missing, or not executable), a command it can't parse (`echo "unterminated`) and output that isn't a
syntax tree all block, with a message saying which. That holds for every Bash call in every repo, opted in or not,
like the jq check. After a merge, run `./install.sh` (it fetches shfmt) before relying on the gate, or every Bash call
blocks.

**The rule.** `tamper_jq` turns the tree into events: every simple command anywhere in it (also those inside command
and process substitutions, and inside an unquoted heredoc body, since those run) and every statement's redirects.
A word is *literal* when all its parts are plain text or quoted text without expansions (escapes and quotes are
resolved, a leading `~` stays text); a variable, a substitution, a glob, a brace list or `$'...'` makes it
*dynamic*. The protected paths are `~` or `$HOME`, then `.claude/(hooks|settings|skills/ship|agents/ship-|bin/)`,
plus `.git/review-gate`. The command blocks when:

- a write redirect (`>`, `>>`, `>|`, `<>`, `&>`, `&>>`, and `>&` when its word isn't a descriptor or `-`) has a
  literal target that is protected, or
- a command whose effective word is a writing tool (`rm`, `touch`, `cp`, `mv`, `ln`, `tee`, `install`, `truncate`,
  `dd`, `chmod`, `sed` with `-i` or `--in-place`, `find … -delete`) has a protected literal word among its words
  (a `cp` that only reads a protected source blocks too: stricter than needed, and what the text check did), or
- a literal word holds a redirect to a protected path (`awk '{ print > "…/.git/review-gate/x" }'`), or
- a literal word is a command line that names a protected path: a writing tool starts it, or follows `;`, `&`, `|`,
  `(`, `{` or a quote, optionally after `sudo`, `env`, `nohup`, `exec`, `command`, `time`, `xargs` or `nice`
  (`watch 'rm ~/.claude/hooks/x'`, `su -c`, `ssh host '…; rm …'`, awk's `system("rm …")`). Prose that mentions a
  tool (`git commit -m "docs: cp of ~/.claude/hooks/x"`) isn't one, or
- the command names a protected literal word and also writes a file other than `/dev/null`, `/dev/stdout` or
  `/dev/stderr` by redirect (`cat ~/.claude/hooks/x >/tmp/y`), as the text check did, or
- a string it runs as shell blocks by these rules: `sh|bash|dash|zsh|ksh|ash -c STRING` and `eval ARGS` are parsed
  again, to a depth of 3.

The *effective word* is the command after leading assignments and these wrappers with their own options: `env`,
`command`, `builtin`, `exec`, `nohup`, `nice`, `time`, `timeout`, `stdbuf`, `sudo`, `doas`, `xargs`, `setsid`; for
`find` it's each command after `-exec`, `-execdir`, `-ok` or `-okdir`. A wrapper option the gate doesn't know
makes the command unreadable.

**The fallback.** When the tree can't settle it, the gate runs the old text check unchanged (apart from adding
`~/.claude/bin/`): a command that names a protected path writes when it runs a writing tool or redirects anywhere
but another descriptor or `/dev/null`, `/dev/stdout`, `/dev/stderr`, with the raw text and the unmarked words both
read, so a quoted `>` counts. It runs when:

- a word of a simple command or a write redirect's target is dynamic;
- a wrapper can't be unwrapped, or `xargs` or `find -exec` hands arguments the command line doesn't show to a
  writing tool (with no protected word among its words) or to a shell or `eval`;
- a writing tool's name (or `sed`, `python`, `perl`) is a later word of a command, behind a wrapper the gate doesn't
  list (`flock`, `ionice`, `watch`, `busybox`), with a protected word among the words;
- one word of a command holds a `>` and another names a protected path (`awk '{ print > "out" }' ~/.claude/hooks/x`);
- a `cd` or `pushd` target is protected (what follows is relative to it);
- a shell runs without `-c` (a script, stdin, `bash <<EOF`, a pipe into `sh`), `source` or `.` runs a file, or
  `python` or `perl` runs without a protected word among its words: their scripts and stdin can write;
- a string run as shell doesn't parse or is nested deeper than 3;
- `disableAllHooks` appears anywhere in the command text.

What the tree check passes that the text check blocked, on purpose: a protected path inside a file name, a quoted
argument when no `>` comes before the protected path inside it (`gh issue create --body "… ~/.claude/skills/ship/x.sh
<PR> …"`, `git commit -m "fix: rm ~/.claude/hooks/x"`), a heredoc body, a read of a protected path piped into a
writing tool whose own arguments aren't protected (`cat ~/.claude/hooks/x | tee /tmp/y`), or a write command and a
read of a protected path that are separate commands (`rm plan.md && ls ~/.claude/agents/x.md`).
What it newly blocks: `sed -ni`/`--in-place`, `find … -delete`, `~/.claude/bin/`. What neither check covers:
tools outside the writing-tool list (`curl -o`, `tar`, `rsync`), since the list can't be complete. What only the
tree check misses: a string handed to a program that runs it where the tool isn't at the start of a command line
inside it (`git commit -m "x; cp …"` reads as a command line and blocks, but `node -e 'fs.writeFileSync("…")'`
passes); the gate catches Claude's slips and isn't a boundary.

## Waivers and opt-in flags

Waivers and the opt-in variables are the user's call, made with `!` (which doesn't run hooks). A command that
mentions `review-gate.sh … --waive`, or `gh variable set|delete|remove` on `CLAUDE_AUTONOMOUS`,
`CLAUDE_ORCHESTRATE` or `CLAUDE_P3_*`, blocks. The user waives from the checkout whose HEAD it waives:

```sh
! ~/.claude/hooks/review-gate.sh --waive "<why>"
```

The waiver is a `<head>.waived` file in the gate's state directory, shared by every worktree of the repository
and keyed by commit.

## Reviewer pipeline

Choices are the user's (2026-10-19). Usage is a Claude Pro plan, so no reviewer uses Opus.

- A Sonnet finder reports P0–P3 findings. A Haiku verifier then checks each one against the code; it may reject
  a finding only by citing the `file:line` that makes it impossible, else the finding stands.
- Confirmed P0–P2 findings block. Confirmed P3s don't: the gate files them as issues with `p3-issue.sh` (labels
  from the repo variable `CLAUDE_P3_LABELS`, default `review:p3`, plus the repo's per-file label map, and an
  optional milestone) and lists them in later prompts so they aren't found twice.
- Docs-only changes get a Haiku claims check instead of a full review. A change is docs-only when every changed
  path is `*.md` or under `docs/`, except `.md` files under `hooks/`, `skills/`, `agents/` or `.claude/` and any
  `AGENTS.md` or `CLAUDE.md`: those prompts, skills, agents and rules steer Claude, so they are behaviour and get
  the full review (#105). A rename counts both its old and new path, and if `git diff` fails to list the changed
  paths the push is blocked.
- Results are cached per HEAD commit and per branch diff (`git patch-id`) in `.git/review-gate/`, so a re-push or
  a clean rebase costs nothing. After a commit passes, later pushes review only the newer commits, with a sweep
  for the same class of bug across the branch. A commit that was already reviewed keeps its findings, so
  re-pushing it re-blocks without a new review.
- The project's review rules come from the default branch's `AGENTS.md` (a branch can't weaken its own review),
  else from the branch's own, which is how the bootstrap PR that adds them gets reviewed. The fallback is for a
  default branch with no `AGENTS.md` or no `## Code Review Rules` section only: an `AGENTS.md` that exists but
  can't be read blocks, on either ref (#152), as the context files below do.
- The rest of the reviewer's context comes the same way: the checklist (the `## Reviews` section of
  `docs/CONTRIBUTING.md`, else `CONTRIBUTING.md`) and `docs/pitfalls.md` are read from the default branch, and from
  the branch only when the default branch has none of that file (the bootstrap PR). A branch that edits them could
  otherwise tell its own reviewer what to skip; its edits are in the diff, reviewed as changes. A file that exists
  on the default branch but can't be read blocks instead of falling back to the branch's copy.
- `docs/false-positives.md` (findings past reviews raised that were judged wrong) is shown to the finder, the
  docs check and the verifier as "Known false positives", from the default branch **only**: unlike the pitfalls
  there is no fallback to the branch's copy, so a branch can't add an entry that silences its own review (its file
  is in the diff, reviewed as a change). When the default branch has none, there is no section. The finder is told
  not to report a matching finding unless the code differs from the entry; the verifier may reject a match, but a
  rejection still needs the `file:line` of the code that shows it is the pattern described (`mark_rejected` ignores
  one without), and names the entry in its reason. Entries are narrow patterns, never a whole class of bug. The ship
  skill adds one when a finding is answered "not valid" or waived.
- The finder prompt also quotes the branch's open PR's unresolved threads from Codex, the owner and collaborators
  (as data, not instructions), so it can check that earlier findings are fixed. The gate reads the PR, the threads,
  the commit list and the diff before it writes the prompt, and blocks when any of them can't be read: an ignored
  failure would read as "no PR", "no threads" or an empty diff, and the review would skip what it was meant to
  check (#106). A branch with no PR, or a PR with no unresolved threads, is reviewed as before.
- Every reviewer run appends its cost to `~/.claude/state/review-costs.jsonl`.
- The reviewer's prompts, schemas, run and verdict rules are in `hooks/review-lib.sh`, which the gate sources and
  `tests/evals/run.sh` uses too, so the evals measure what the gate sends (see Changing prompts or models). It is
  deployed and protected like the gate. A shell that fails to source a file exits with a status Claude Code lets
  through, so the gate checks that it can read the lib first, and blocks when it can't. It blocks too when a prompt
  file can't be read, since a prompt built without the reviewer's instructions would still look built.
- The reviewers share one time budget, `REVIEW_GATE_BUDGET` (default 2200 s) counted from the gate's start: each run
  gets `min(1100 s, what is left)`, and none starts with fewer than `REVIEW_GATE_MIN_SECS` (default 120 s) left; the
  gate then blocks with "ran out of time". Two reviewers at 1100 s each would otherwise outlast the hook's timeout
  (2400 s, README › Install). A finder's result is kept, so the retry resumes at the verifier. A value that isn't
  a plain number blocks. A reviewer that times out (`timeout` exits 124) or fails blocks like any failure.

**Reviewers only read.** `--tools` makes Read, Grep and Glob the only built-in tools (no shell, since even
`git diff --output=<file>` writes), and `--strict-mcp-config` with no config loads no MCP or plugin tools,
whatever the user's settings allow. The branch can't steer its own review: `--safe-mode` skips its CLAUDE.md,
hooks, skills and plugins, and `--restricted` ignores the user and project settings files and keeps the file
tools inside the repo (`--bare` would too, but needs an API key). Managed settings and policy hooks still load
under both; they're the machine owner's, not the branch's. The prompt carries the diff and log, and the working
tree is the commit being pushed (the gate refuses a dirty tree and pushes of anything but HEAD).

## Changing prompts or models

A change to what a reviewer is told or how it runs (`hooks/review-prompt.md`, `review-docs-prompt.md`,
`review-verify-prompt.md`, and the schemas, models or flags in `hooks/review-lib.sh`) can make the gate catch more
bugs or fewer, and a read of the diff can't say which. So a PR that makes such a change includes a before and after
result of `tests/evals/run.sh` in its description: the runner's output on the base and on the branch (each from its
own checkout, or the base's with `--prompt-dir` pointing at the branch's `hooks/`), and `--model-finder` and friends
for a model change.

**What it is.** `tests/evals/cases/<name>/` holds one case: a `change.diff` with a seeded bug (or a clean change) and a
`case.json`: `base` (a full commit sha of this repo that the diff applies on), `kind` (`code` or `docs`, which must be
what the gate's kind check says of the diff), `expect` (the findings a reviewer should report, each `{file, line,
severity}` with `line` in the changed file; `[]` for a clean case), `source` (the pitfall, issue or PR it comes from)
and an optional `commit` (the subject the reviewer sees in the commit list). The runner makes a detached worktree at
`base`, commits the diff, and builds the prompt with the gate's own code (`hooks/review-lib.sh`, which the gate sources
too), reading the rules, the checklist, the pitfalls and the false positives from `base`, not from the working tree. It then runs the gate's
stages with the gate's flags: the Sonnet finder, then the Haiku verifier when the finder found something (a docs case
gets the Haiku claims check and no verifier). Cost rows go to a temporary file, not to
`~/.claude/state/review-costs.jsonl`.

**Scoring.** A finding matches an expected one when the file is the same and its line is within 3 lines. An expected
bug is *caught* when a matching finding has its severity, a *wrong severity* when the matching findings have another
one, and *missed* when none match. A finding that matches nothing is a *false positive*; two findings on one bug are
one catch. Each case is scored after the finder and again after the verifier (the findings it rejected with a
`file:line` citation dropped, as the gate does). A reviewer that fails, times out or returns nothing readable makes the
case an *error*, counted apart from *missed*, since a flaky run says nothing about the prompt (its row still carries
the cost of the failed run, so totals show what a failing configuration spends). A `--prompt-dir` that lacks the lib
or a prompt is a setup error before any case runs. `INT` or `TERM` stops the running reviewer at once and removes the
worktree and temp directory. A case whose `base` isn't
in the clone (a shallow checkout) is skipped. The runner prints a line per case and stage, then totals per stage and
model with their cost; `--json` prints the same as JSON. It exits 0 whatever the score. `--check` only sets the cases up
(valid `case.json`, the diff applies, the kind matches, the expected lines exist, the prompt builds) and exits 1 when a
case fails.

**Cost.** Each run calls real `claude` sessions, about as much as the gate's reviews of that many pushes, so run it by
hand and keep it out of CI. `tests/gate-evals.sh` (in the normal checks) tests the scoring with a fake `claude`, and
runs `--check` on the seeded cases, so a case whose diff stops applying fails without tokens. CI checks out the whole
history for that, since the cases apply on old commits.

**Adding a case.** When a review (the gate's or Codex's) misses or wrongly reports something, turn it into a case:

1. Take the commit the bug was introduced on top of (a commit of `main`, so its sha stays reachable) as `base`.
2. Write the smallest realistic change at that commit that has the bug (or a correct one, for a clean case), and save
   its diff as `change.diff`.
3. Write `case.json`, with the file and line of the bug in the changed file and the severity the rules give it.
4. Run `tests/evals/run.sh --check --case <name>`, then once for real with `--case <name>`.

The first cases come from [`pitfalls.md`](pitfalls.md): one per class that bit this repo's own files, plus three clean
changes (a refactor, a docs sentence and a test).
