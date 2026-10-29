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
repo that isn't opted in, a directory that isn't a git repo and a repo with no GitHub remote still pass, as before.

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

The installed gate, its prompts, the ship skill and agents, the gate's state (`.git/review-gate/`) and the
settings that register it are the user's to change; claude-ship's source changes through reviewed PRs. `Write`,
`Edit`, `MultiEdit` and `NotebookEdit` calls on those paths block. A project's own `.claude/settings` may change,
but not to turn hooks off (`disableAllHooks`).

For Bash, writing gate state or the installed gate would bypass the review; reading its reports is fine. A
command that names a protected path writes when it:

- runs a writing tool (`rm`, `touch`, `cp`, `mv`, `ln`, `tee`, `install`, `truncate`, `dd`, `chmod`, `sed -i`,
  `python`, `perl`), or
- redirects output anywhere but another descriptor (`2>&1`, `>&2`) or `/dev/null`, `/dev/stdout`,
  `/dev/stderr`. A quoted `>` counts too, since `sh -c "… > f"` and `awk` redirect inside quotes.

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
  else from the branch's own, which is how the bootstrap PR that adds them gets reviewed.
- The rest of the reviewer's context comes the same way: the checklist (the `## Reviews` section of
  `docs/CONTRIBUTING.md`, else `CONTRIBUTING.md`) and `docs/pitfalls.md` are read from the default branch, and from
  the branch only when the default branch has none of that file (the bootstrap PR). A branch that edits them could
  otherwise tell its own reviewer what to skip; its edits are in the diff, reviewed as changes. A file that exists
  on the default branch but can't be read blocks instead of falling back to the branch's copy.
- Every reviewer run appends its cost to `~/.claude/state/review-costs.jsonl`.
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
