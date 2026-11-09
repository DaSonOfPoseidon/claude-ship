# The pre-push review gate: design notes

`hooks/review-gate.sh` is a PreToolUse hook. It blocks a canonical `git push` until an independent
reviewer (a fresh headless Claude session with no context from the current one) has reviewed the branch diff
against the repo's default branch. The script keeps only short comments on its checks and regexes; the reasons
behind them are here. Classes of bug past reviews caught are in [`pitfalls.md`](pitfalls.md).

The gate catches Claude's own slips; it isn't a security boundary. It judges command text, and its state is
writable by any shell. Branch protection requiring the `codex-review` status is the server-side backstop for
merges. What counts as a gap and what doesn't: [Threat model](#threat-model).

Exit 0 allows the tool call; exit 2 blocks it and shows stderr to Claude.

## Threat model

**Purpose.** The gate stops Claude's own slips: a push made without thinking, a chained `git commit && git push`,
an edit to the installed gate. It does not defend against a command written to get past it. Its command checks
read text (and a syntax tree of it); its state is writable by any shell.

**In scope.** A finding about a command check needs a command Claude could plausibly run unprompted: literal
words, in a form the repo's docs, skills or scripts use, or common git/gh/shell practice. The canonical forms:
`git push --no-verify`, `git -C dir push`, `cd dir && git push`, `git push 2>&1 | tail -5`, `/usr/bin/git push`,
and a GitHub API write the ship skill doesn't use. One that reaches an opted-in repo without a passing review is
a P0.

**Out of scope at every priority** (AGENTS.md › Code Review Rules › Gate scope). Reviewers and Codex don't report
them, and the answer to such a finding is the rule, not another entry in a list:

- *A command, path or setting built at run time* (variables, `$(…)`, `eval`, aliases, functions):
  `declare -n ref='a[$(git push)]'`, `printf '%n'`, `exec -l bash`, `xargs env git push`, `rm $(cat list)`,
  `ls | xargs rm`.
- *Code an interpreter reads from a string, a file or an environment variable*: `node -e 'fs.writeFileSync("…")'`,
  `python3 s.py`, `PERL5OPT=-M… shasum`.
- *Another tool's option that runs a command*: `rg --hostname-bin`, `xargs find`.
- *A link, copy or rename onto a protected file*: a symlink to a protected path.
- *A setting changed only to skip a check*: `HOME`, `GIT_CONFIG_*`, `-c` keys that turn hooks off (the inputs of
  claude-ship #200–#203).

The first three classes include the P0s of claude-ship #191 (`rg --hostname-bin`, `xargs env`,
`declare -n ref='a[$(git push)]'`, `PERL5OPT=-M… shasum`, `printf '%n'`, `exec -l bash`): one codex round each,
none a command Claude would run.

Checks that block a literal form today stay (a `cp`, `mv` or `ln` that names a protected path, the writing-tool
list in Tamper protection); what is out of scope is a finding that a variant of these classes gets past them.

**Layers that don't read text.** Branch protection requiring `codex-review` blocks a merge whatever the command
was. It doesn't bind admins (`enforce_admins` is off), so an admin push to the default branch skips it. A way past
branch protection that a plausible command takes is in scope.

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

The gate reads a Bash command three ways: the raw text, a list of words as the shell would split them (`shell_words`, run by
jq) and the syntax tree shfmt makes of it. The command must parse, or the call blocks.

In the word list, quotes and backslashes go and every character they made literal becomes a marker, so `git -c "a=b c" push`
and `git "push"` read as the push they are and a quoted `;` can't pass for a separator.

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

Inside double quotes `$` and backticks still expand, so they stay as they are. Checks that read text rather than structure
see both the raw command and its unmarked words (`cmd_all`), so quoting (`CLAUDE_AUTONO''MOUS`, `c''d`) can't split a name
apart. The tree is what the tamper check reads (Tamper protection below), and what decides whether a command is a push.

**What starts a review.** The gate starts a review for a *canonical push* and for nothing else (the `gh api` calls below
aside). Every other command passes once the tamper, waiver, opt-in-variable and pre-push-check denials above have looked at
it. It used to hunt for pushes it could not read: a filter (`runs_gitgh`) for commands that run no git, text checks for a
push hidden in a heredoc, a `gh pr create` trigger, and a soft path that followed `cd`s that might not run. Those caused
false blocks (claude-ship #192, #193) and bypasses (#191) for every shape the text could not settle. Since the
[pre-push check](#pre-push-check) refuses an unreviewed push however it started, the gate no longer has to find them all.

A canonical push is one statement, and in it the git command is first in its pipeline and its subcommand is `push`
(after any global options): `git push ARGS` or `PATH/git push ARGS`, alone or after leading `cd ARGS &&` commands, and
optionally piped on (`git push 2>&1 | tail -5`). The subcommand is found on the tree's literal words, skipping the global options
and their values.

| Command, in an opted-in repo | Result |
|---|---|
| `git push`, `git push -u origin HEAD`, `cd /abs/repo && git push`, `git -C ~/repo push`, `git push 2>&1 \| tail -5` | reviewed |
| `git push origin "$b"`, `cd "$d" && git push`, `cd a && cd b && git push`, `git -C a -C b push` | blocked: the gate can't tell which repo, or what, it pushes |
| `--all`, `--tags`, `--mirror`, another remote, `--no-verify`, `GIT_DIR=x git push`, a redirect to a file | blocked (Push shape) |
| `git add -A && git commit -m x && git push`, `git push; echo`, `(cd x; git push)`, `bash -c 'git push'`, `xargs git push`, `timeout 60 git push`, `./scripts/release.sh`, an alias, `gh pr create --fill` | passes; the pre-push check judges the push, if one happens |
| a heredoc or an argument that only mentions `git push` or `gh api` (#193, #192) | passes |

`git commit && git push` is the case that matters most: the gate would review the HEAD from before the commit, so it does
not look at the chain, and the hook refuses the push if the new commit has no review (`tests/git-hook.sh` runs that chain
for real). `gh pr create` starts no review either: the PR covers a HEAD the hook already stopped from being pushed unreviewed.

The pre-push check is the layer that binds the cases the gate lets by. What the gate still reads in *every* command is the
tamper check, the waiver and variable checks, the denials that keep the hook on (`push --no-verify`, a write of
`core.hooksPath`) and whether the hook is on in the session's repo (all in Pre-push check › The gate keeps it on), all before
the trigger above.

**Quoting.** A canonical push, or a command with a `gh api` call, whose quoting the scanner can't read (it already holds a
marker, or the push's own words have literal separators, quotes, `$` or newlines) can't be checked word by word, so it blocks.

**`gh api`.** The hook never sees an API write, so the gate still scans `gh api` calls. A command is scanned when its text
shows `gh api` and its tree names a literal `gh` as a word of a command that may run it (`gh`, `/usr/bin/gh`, behind `sudo`,
`xargs`, `flock`, or in a string run by `sh -c` or `eval`; a string the gate can't parse counts as naming one). A heredoc body,
the words after an `echo` or `printf`, or a quoted `grep` pattern that only mention `gh api -X DELETE …` name no `gh`, so they are
data and pass. A scanned call writes when its method isn't GET (gh's
default once it has fields or an `--input`), and passes only if it is one of the writes the ship skill makes (REST allowlist
below). A write that names `{owner}/{repo}` goes to whichever repo gh finds where it runs, so the opt-in lookup also asks the
directory of every `cd` the tree shows, whether or not the command is a push (a `cd` that is not one literal path blocks).
`tests/gate-api.sh` and `tests/gate-push.sh` cover it.

`git` and `gh` may be named by a path (`/usr/bin/git`, `./gh`), so `/` counts as a word boundary before them in the text
checks; `.`, `_` and `-` don't (`.git/`, `my-gh`).

## Push shape

The review covers HEAD, so a push may send only HEAD (or one tag, below), to origin, and only when every origin URL (fetch and
push) is the same GitHub repo. Git fetches from the first URL and pushes to all of them, and `github_slugs`
drops URLs that aren't GitHub's, so a local path among them would go unseen. The review diffs against the
default branch and reads its rules through origin's fetch URL, so that must be the repo the push lands in.

`github_slugs` reads any scheme, user and port, any host case, GitHub's ssh-over-443 host, and a
fully-qualified host's trailing dot (`github.com.`). A URL whose host is github.com (or under it) but doesn't
parse prints as `?<url>`, and callers fail closed on it. Other hosts and local paths aren't GitHub.

Only these push options pass: `-u`, `--set-upstream`, `-f`, `--force`, `--force-with-lease*`,
`--force-if-includes`, `-q`, `--quiet`, `-v`, `--verbose`, `-n`, `--dry-run`, `--progress`, `--atomic`. Any other option
blocks, since some (`--all`, `--mirror`, `--tags`, `--delete`) send other refs; `--no-verify` is one of them now, because it
skips the [pre-push check](#pre-push-check), which also refuses an unreviewed push this shape check doesn't recognise. A refspec's destination is checked as well as its source: `HEAD:other` or `HEAD:refs/tags/x` writes a ref
the review didn't cover. Config that changes what a bare push sends blocks too: `push.default` `matching`, or
`upstream`/`tracking` when the branch tracks another one; `remote.origin.push`; `push.followTags`;
`push.recurseSubmodules` `on-demand` or `only`; `remote.origin.mirror`.

**A tag push** is the one other thing a push may send: exactly `git push [-f|--force] origin <tag>` or
`... origin refs/tags/<tag>` (`tag_push` in `hooks/review-gate.sh`; `-C DIR` and `cd DIR &&` as for any push), where
`<tag>` is an existing local tag. One tag, no other option, remote or refspec (`--tags`, `HEAD:refs/tags/x`,
`v1:refs/heads/main`, `+v1`, `--delete`), and a bare name that is also a branch, or `HEAD`, is not a tag. The checks on
`push.followTags` and `remote.origin.mirror` and on global options still apply. Such a push sends no HEAD, so the gate
reviews nothing and lets it through: the [pre-push check](#pre-push-check) decides on the tag's commit.

Git global options other than one `-C <dir>` (`-c push.default=matching`, `--git-dir`, ...) can change what's pushed
or from which repo, and block. Environment overrides never get that far: only the push may run. The tree allows only
`-C <dir>` between `git` and `push`; the text check for `-c`, `--git-dir` and the like, and for a single `-C`, also
still runs over the whole command in both forms.

**What may run next to the push.** The checks read git config, refs and files before the command runs, so
anything earlier in the command can change what the push sends after they passed: `git show --output=…`, or
`printf … > /tmp/settings` behind an `include.path`. Such a chain is not a canonical push, so the gate leaves it to the
pre-push check, which judges the commit that is really pushed. A canonical push holds only:

- the push,
- at most one leading `cd <dir> &&`,
- harmless redirects (`/dev/null`, `/dev/stdout` or `/dev/stderr` as a literal target, and descriptor
  duplications such as `2>&1`, `>&2` and `>&-`), and
- trailing pipes into read-only filters (`tail`, `head`, `cat`, `grep`).

`push_jq` decides that on the syntax tree (the one the tamper check reads), as an allowlist of tree shapes: a canonical push
that doesn't fit blocks, and nothing is a list of what is dangerous. The statement must be `git push ARGS` (`git` or `PATH/git`,
whose only global option is one `-C <dir>`), `cd DIR && git push ARGS`, or either piped into `tail`, `head`, `cat` or `grep`.
Every word in every command must be literal (`wv`): a variable, a command substitution, a glob or a brace expansion blocks.
A redirect passes only to a literal `/dev/null`, `/dev/stdout` or `/dev/stderr`, or between descriptors (`>&-` too); one to any
other file, a here-document, a here-string, an input redirect and a `{fd}` redirect block. Also blocked: an assignment before
the command (`GIT_DIR=x git push`), a negation, a background `&`, a trailing `;`, a comment, a pipe into anything else, `|&`, an
empty or newline-containing word, and any key of the tree that the program doesn't list, so a newer shfmt fails closed. Reading
the tree instead of text is what lets `cd "dir with space" && git push` and a push continued with a backslash-newline
pass (#39, #42), and a quoted redirect target (`>'/dev/null'`, #99), as the same command in another spelling. `push_scope` takes
the option and refspec checks' words from the tree too, so `'orig'in` and `"HEAD"` are read as the shell would (the one-push rule
still counts `git push` in the text of both command forms).

**Where the push runs.** The session's directory, then the `cd DIR` before the push, then `git -C DIR`; the repo found there is
the one checked. `DIR` must be a single literal path: `~` and `~/…` are the home directory (`~name` is not literal), a relative
path is taken from the session's directory, and a `-C` one from the `cd` target. A second `cd`, a second `-C`, a `cd -`, an
empty directory, a variable or a substitution can't be followed, so the gate blocks ("can't tell which repo this pushes"), in
any repo, since the directory could be an opted-in one. A directory that can't be entered blocks too. A repo that hasn't opted
in is none of the gate's business: a canonical push that doesn't fit the shape passes there, as `git push && echo done` does.
The `cd` and `-C` words come from the tree, so `-C "dir with space"` and a `git -C …` inside a quoted string can't change the
directory.

## Pre-push check

The gate starts a review only for a canonical push ([Command reading](#command-reading)), so a push that starts some other
way (a script, a compound command, `bash -c`, a wrapper) would reach an opted-in repo unreviewed. Git itself closes that: `install.sh` sets the global
`core.hooksPath` to `~/.claude/git-hooks`, and `hooks/git-hook.sh` runs from the stubs there. Its `pre-push` refuses
Claude's push of a commit with no `.pass` or `.waived` in the review state, whatever started the push. It is a backstop
for the gate, not a second reviewer: it only reads the state the gate writes (and the user's waiver).

**Whose pushes.** The check applies to Claude's pushes only, so the user's own pushes are untouched. A push is Claude's when
`CLAUDE_CODE_CHILD_SESSION` is `1` (the variable Claude Code sets for the processes it starts; the npm install runs as
`node`, so the process name alone would miss it) or a process named `claude` is among the hook's ancestors (walked with
`ps`, at most 64 steps, stopping at PID 1; this covers `sudo` and `env -i`). The user's `!` commands inside Claude Code
count as Claude's: `! git push --no-verify` skips the check. Without `ps` and without the variable, a push counts as the
user's.

**What it checks.** The destination is found first: the remote's configured push URLs (`remote.<name>.pushurl`, else
`remote.<name>.url`, before any `insteadOf` rewrite), the first argument itself (a push by URL passes the URL as typed
there, and the rewritten one as `$2`) and the URL git resolved (`$2`), read with `github_slugs`, so a `pushurl` that
differs from the `url`, or a push by URL that a rewrite turns into a non-GitHub one, can't hide a GitHub repo. A destination that isn't GitHub is not
checked. Each repo's `CLAUDE_AUTONOMOUS` is read with `autonomous` (both in `hooks/gate-common.sh`, shared with the
gate): opted in means enforce, not found means the next repo, and an error (GitHub down, `gh` missing or logged out) refuses
the push, as the gate does. Then each line git sends (`<local ref> <local sha> <remote ref> <remote sha>`) is judged
on its own, by the commit it pushes and not by HEAD:

| Line | Result |
|---|---|
| local sha is all zeros (a delete) | allowed |
| the sha isn't a full object name, or isn't a commit (a tag is peeled to its commit) | refused |
| the remote ref is under `refs/tags/` and the commit is on the remote's default branch | allowed |
| the remote ref is under `refs/tags/` and it isn't (a local `.pass` or `.waived` doesn't count) | refused |
| `<common dir>/review-gate/<commit>.pass` or `.waived` exists (any other ref) | allowed |
| anything else, including a malformed line | refused |

**Tags of merged commits.** A squash-merge commit never has a local `.pass` (it was made on GitHub), but it went through a PR
with the gate, CI and Codex, so a tag of it sends nothing unreviewed. A tag is a release, so it is judged by this rule alone,
before the review state is read: a reviewed feature commit can't be released before it is merged. A tag line is allowed
when its commit is an ancestor of the default branch's tip **as the remote reports it now**: `git ls-remote --symref <url> HEAD`
against the URL the push goes to (`$2`), exactly one `HEAD` line with a full object name, the tip fetched from that URL if
the clone lacks it, then `git merge-base --is-ancestor`. Local refs are not evidence (`refs/remotes/origin/main` is
whatever `git update-ref` says), so they are never read. Anything it can't tell refuses, naming the reason: no URL, the
network (a 60 s bound, no credential prompt, no stdin), output it can't read, a tip it can't fetch, a shallow clone. A commit
only on another remote branch, or only local, is refused. Branch lines keep the table's rule: a merged commit pushed to a
branch still needs its own review. Redirecting the remote itself (`url.<x>.insteadOf`, `remote.origin.url`) is outside the
gate's scope (AGENTS.md › Gate scope).

One refused line refuses the whole push. The state is the common directory's, shared by the worktrees. Every push the
gate lets through for an opted-in repo therefore leaves a `.pass` for HEAD, including a branch whose diff against the
default branch is empty (nothing to review counts as passed). The refusal tells
Claude to run a plain `git push` on its own so the gate reviews HEAD, not to skip the check, and to ask the user to waive
a wrong review.

**Chaining.** Setting `core.hooksPath` makes git stop running a repo's own `.git/hooks`, so every stub runs the repo's hook
of the same name (`<common dir>/hooks/<name>`) with git's arguments and stdin, and exits with its status; `pre-push` does
so after its own check (and only if that passes). One stub exists for each hook git 2.34 runs from the hooks directory
(`git help hooks`) except `push-to-checkout`, `proc-receive` and `fsmonitor-watchman`, whose presence alone changes what
git does. The stubs `exec sh '<dest>/hooks/git-hook.sh' <name> "$@"`.

**The gate keeps it on.** `push --no-verify` and a write of `core.hooksPath` (`git config` in any form but a read,
`-c core.hooksPath=…`, `--config-env=core.hooksPath=…`, the key in any case) are denied wherever the gate sees them, read
from the syntax tree like the tamper checks (so `sh -c` and `sudo` are unwrapped).

On top of that, every Bash command is checked for the hook being on, with no reading of the command's text: a push the gate
does not start a review for is left to the hook, and a repo's own `core.hooksPath` (husky and the like, often set by an install
script) replaces ours for every push. The gate does not try to tell which repo a command works in (a `cd`, `git -C`, a script, a
wrapper: every spelling the scan missed was the next finding, claude-ship #222), it looks at the checkouts instead:

- the local config of every checkout directly under `/srv/CodeServer` (`.git/config`, `.git/config.worktree`, and the
  `config.worktree` of its linked worktrees under `.git/worktrees`), and of the session's own repo (found from the working
  directory; a linked worktree's shared config too), for a `core.hooksPath` in `[core]` that isn't the deployed directory
  (`~/` is the home directory). `REVIEW_GATE_SCAN_ROOT` replaces `/srv/CodeServer`; the tests use it so the machine's own
  checkouts stay out of them;
- the session's repo, whether the hook is on there at all: `git config --get core.hooksPath` is
  `${CLAUDE_HOME:-$HOME/.claude}/git-hooks` and its `pre-push` is executable (install.sh not run, or the hook deleted).

These are plain file reads while all is well: the global config is searched for the deployed path, and `git` and `gh` run only for
a checkout that looks off, which is then asked for its opt-in (`CLAUDE_AUTONOMOUS`; GitHub unreachable blocks). An override in a
repo that has not opted in is left alone. For an opted-in one, every Bash command blocks, wherever it runs, with the path, the value
and what the user should run (`./install.sh`, or `git config --local --unset core.hooksPath` in that repo: Claude can't, the write is
denied above). Includes (`include.path`) and a `GIT_DIR` or `GIT_CONFIG_*` set in the command are not read (Gate scope), and a
checkout outside `/srv/CodeServer` is covered only while it is the session's own. A canonical push is also checked by git's own
value in the directory it runs in (Push shape). `--no-verify` is no longer one of the push options the gate allows (Push shape).

The stubs in `~/.claude/git-hooks` are protected like the installed hooks (Tamper protection): a Write, or a Bash command
that writes there, blocks. The lines git sends are saved to a temp file first; if that save fails (full disk, file size
limit) the push is refused, not read as an empty list.

Not covered: a Claude push that never reaches a git hook (the GitHub API, MCP writes: those are the gate's), a
setting changed with a command the gate can't read (Threat model), and where a push in a non-canonical command goes: the hook
checks that the pushed commit was reviewed, not the destination (`git push origin HEAD:main && …` sends a reviewed feature commit
to `main`). The gate's destination checks (Push shape) hold for a canonical push only; branch protection requiring `codex-review`
is the backstop for the rest.

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
the settings that register it, the managed settings directory (`/etc/claude-code`, where `install.sh` puts the gate's
drop-in) and shfmt (`~/.claude/bin/`, which the gate reads every Bash command with, so replacing it would blind the
gate) are the user's to change; claude-ship's source changes through reviewed PRs. `Write`,
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
resolved, a leading `~` stays text, `$HOME` and `${HOME}` alone are the home directory); a variable, a substitution,
a glob, a brace list or `$'...'` makes it *dynamic*. The protected paths are the home directory, then
`.claude/(hooks|git-hooks|settings|skills/ship|agents/ship-|bin/)`, plus `.git/review-gate` and the managed settings
directory `/etc/claude-code` (the whole directory: a policy file added there could override the gate's registration; it
is a fixed path because Claude Code reads that one, whatever `CLAUDE_SHIP_MANAGED_DIR` says to the installer). A path is
compared **after it is resolved** (below), never as the text it was written as. The command blocks when:

- a write redirect (`>`, `>>`, `>|`, `<>`, `&>`, `&>>`, and `>&` when its word isn't a descriptor or `-`) has a
  target that is protected once resolved, or
- a command whose effective word is a writing tool (`rm`, `touch`, `cp`, `mv`, `ln`, `tee`, `install`, `truncate`,
  `dd`, `chmod`, `sed` with `-i` or `--in-place`, `find … -delete`) has a word that resolves to a protected path
  among its words (a `cp` that only reads a protected source blocks too: stricter than needed, and what the text
  check did), or one of the writers below has a protected target, or
- a literal word holds a redirect to a protected path (`awk '{ print > "…/.git/review-gate/x" }'`), or
- a literal word is a command line that names a protected path: a writing tool starts it, or follows `;`, `&`, `|`,
  `(`, `{` or a quote, optionally after `sudo`, `env`, `nohup`, `exec`, `command`, `time`, `xargs` or `nice`
  (`watch 'rm ~/.claude/hooks/x'`, `su -c`, `ssh host '…; rm …'`, awk's `system("rm …")`). Prose that mentions a
  tool (`git commit -m "docs: cp of ~/.claude/hooks/x"`) isn't one, or
- the command names a protected literal word and also writes a file other than `/dev/null`, `/dev/stdout` or
  `/dev/stderr` by redirect (`cat ~/.claude/hooks/x >/tmp/y`), as the text check did, or
- a string it runs as shell blocks by these rules: `sh|bash|dash|zsh|ksh|ash -c STRING` and `eval ARGS` are parsed
  again, to a depth of 3.

**Resolution** (#187). The text of a path is not the file: `~/.claude/./hooks/x`, `~/.claude//hooks/x`,
`~/.claude/y/../hooks/x`, `${HOME}/.claude/hooks/x`, `~root/.claude/hooks/x`, and `rm hooks/x` after `cd ~/.claude` are
all the same file. So every word of a writer and every redirect target is resolved before the comparison with the
protected list, lexically (no filesystem access, so **symlinks are out of scope**: a link to a protected directory
passes):

- `~`, `~/…`, `~<own user>`, a leading `$HOME`/`${HOME}` (also inside double quotes) are the home directory. Any other
  `~name` has a home the gate doesn't know: it blocks a writer when the rest of the word has `/.claude/` or ends in
  `/.claude`, and is dynamic otherwise.
- `//`, `/./`, a trailing `/.` and `seg/..` are folded (a `..` above `/` stays at `/`), and a relative word is made
  absolute from the working directory: the hook input's `cwd` (the `$PWD` of the gate without one), moved by the `cd`
  and `pushd` the command runs. A `cd` that runs first (alone, or on the left of `&&`; `a && cd b && c` follows it in
  order, each one only for what comes after it in the chain) sets the directory for what follows; after an `&&` chain
  both the directory before it and the one it ended in are candidates, since a `cd` in it may not have run. A `cd` that may not run in order (after `||`, in an `if`, a loop, a block,
  a function, a substitution) adds a **candidate**: the statement's relative words are resolved from the directory
  before it and from every such target, and are protected when any of them is. A `cd` in a subshell, a pipeline or the
  background doesn't leave it. A `cd` to something dynamic (`cd $d`, `cd -`, `popd`) makes the directory unknown, and
  relative words stay with the fallback below; so does a `cd` inside a string run by `eval` (the string's own commands
  start from the directory the `eval` runs in, but its `cd` doesn't carry out). More than 32 candidates become unknown
  too. `env -C DIR` and `sudo -D DIR` add DIR as one more candidate.
- A word with a dynamic, glob or brace part is cut at it: when the **literal start** resolves to `~/.claude`, below it, or
  to a path whose rest could still be a protected file (`~/.claude/$x/…`, `~/.claude/hook?/…`, `~/.claude/{hooks,y}/…`,
  `~/.claude/s*`; likewise `/etc`, `/etc/$x/…` and `/etc/claude-$x/…` for the managed directory), a writer with it blocks. `~/.claude/projects/$x` doesn't, and neither does a start of just `~/` or `/`
  (`rm ~/$x`, `rm ~/.*.swp`): those stay with the fallback, so `rm` of a variable isn't blocked everywhere.
- The old text comparison still counts as well, on the word as written, so nothing the text check blocked passes now
  (`/dev/null,~/.claude/hooks/x`): a word's `NAME=VALUE` value is resolved too (`of=hooks/x`,
  `--target-directory=~/.claude/hooks`).
- A relative word is resolved from the working directory only if it can be a file name. The command's own name, the first
  word, options, a number (`644`, `4M`), a symbolic mode (`u+x`) and a sed script (`s/a/b/`) are not, and for `NAME=VALUE`
  only the value is a path (`dd if=/tmp/a of=/tmp/b` in `~/.claude/hooks` passes). They still count as written or when
  absolute.
- The `Write`, `Edit`, `MultiEdit` and `NotebookEdit` path is folded the same way (relative to the same `cwd`) before the
  protected-path check, and also checked as written.

**More writers** (#187): each blocks only when its target resolves to a protected path (a download, an archive or a
copy elsewhere passes, and so do the forms that write no file: `-o -`, `tar -O`, `tar -cf -`, `wget --spider`): `curl -o|--output FILE` and `--output-dir DIR`, `curl -O|--remote-name` into the current
directory; `wget -O FILE`, `wget -P DIR`, and `wget` into the current directory; `tar` with `-C|--directory DIR` when it
extracts (into the current directory without one) and `-f|--file FILE` when it creates or appends (`c r u A`); `rsync`
and `scp`, last argument (a `host:path` is remote); `sponge FILE`; `node`, `nodejs`, `ruby` and `php`, like `python`
and `perl`; and `git -C DIR SUB` when DIR is under a protected directory or is `~/.claude` itself, unless SUB is one of
`status`, `log`, `diff`, `show`, `rev-parse`, `ls-files`.

The *effective word* is the command after leading assignments and these wrappers with their own options: `env`,
`command`, `builtin`, `exec`, `nohup`, `nice`, `time`, `timeout`, `stdbuf`, `sudo`, `doas`, `xargs`, `setsid`; for
`find` it's each command after `-exec`, `-execdir`, `-ok` or `-okdir`. A wrapper option the gate doesn't know
makes the command unreadable.

**The fallback.** When the tree can't settle it, the gate runs the old text check unchanged (apart from adding
`~/.claude/bin/`, the in-place `sed` forms and the writers above): a command that names a protected path writes when it runs a writing tool or redirects anywhere
but another descriptor or `/dev/null`, `/dev/stdout`, `/dev/stderr`, with the raw text and the unmarked words both
read, so a quoted `>` counts. It runs when:

- a word of a simple command or a write redirect's target is dynamic;
- a wrapper can't be unwrapped, or `xargs` or `find -exec` hands arguments the command line doesn't show to a
  writing tool (with no protected word among its words) or to a shell or `eval`;
- a writing tool's name (or `sed`, `python`, `perl`) is a later word of a command, behind a wrapper the gate doesn't
  list (`flock`, `ionice`, `watch`, `busybox`), with a protected word among the words;
- one word of a command holds a `>` and another names a protected path (`awk '{ print > "out" }' ~/.claude/hooks/x`);
- a `cd` or `pushd` target is protected (it settles nothing by itself: the writes that follow are resolved from it, and
  the fallback only reads the text);
- a shell runs without `-c` (a script, stdin, `bash <<EOF`, a pipe into `sh`), `source` or `.` runs a file, or
  `python` or `perl` runs without a protected word among its words: their scripts and stdin can write;
- a string run as shell doesn't parse or is nested deeper than 3;
- `disableAllHooks` appears anywhere in the command text.

What the tree check passes that the text check blocked, on purpose: a protected path inside a file name, a quoted
argument when no `>` comes before the protected path inside it (`gh issue create --body "… ~/.claude/skills/ship/x.sh
<PR> …"`, `git commit -m "fix: rm ~/.claude/hooks/x"`), a heredoc body, a read of a protected path piped into a
writing tool whose own arguments aren't protected (`cat ~/.claude/hooks/x | tee /tmp/y`), or a write command and a
read of a protected path that are separate commands (`rm plan.md && ls ~/.claude/agents/x.md`).
What it newly blocks: `sed -ni`/`--in-place`, `find … -delete`, `~/.claude/bin/`, the other spellings of a protected path
and the writers above. What neither check covers is out of scope by design: see [Threat model](#threat-model).

**`chattr` is denied** (#189). `chattr` sets and lifts the immutable flag that locks the installed files (below), so any
call whose effective command is `chattr`, behind the wrappers above and `find -exec`, `xargs` or a string run as shell,
blocks with a message asking the user to run `! chattr -i <path>` themselves. `lsattr`, and a `chattr` that is only a
word (`grep -n chattr install.sh`, `echo chattr`, a file called `chattr.md`), pass. The fallback blocks a command it can't
read when the word `chattr` stands on its own in it (`c=chattr; $c -i x`), since it can't tell a command from an
argument there. `install.sh` itself is not affected: the gate sees `./install.sh`, not what runs inside it.

**Immutable install** (#189). The text checks above stop what Claude plausibly types; they don't stop a command written to
get past them. So `install.sh` also takes the files out of reach of any command Claude runs, without relying on how the
command is spelled:

- **Managed settings.** It copies `settings/claude-ship.json` to
  `/etc/claude-code/managed-settings.d/claude-ship.json` (`CLAUDE_SHIP_MANAGED_DIR` moves it, for the tests). Managed
  settings are the machine owner's: user and project settings can't turn the hook off or override it. The hook is the same
  handler as the README's snippet (a test compares them), so while that snippet stays in `~/.claude/settings.json`,
  Claude Code runs the gate once, and `install.sh` never edits that file. Once `/status` lists "Enterprise managed
  settings (drop-ins)", the user can remove the gate's entry from their settings; until then it is the fallback if Claude
  Code doesn't read the drop-in. The file is validated with `jq` (exactly one JSON value, the gate's `PreToolUse` hook with
  `timeout` and `onFailure: block`) before the installer changes anything, and moved into place from a temp file
  beside it, because a managed file that isn't valid JSON stops Claude Code from starting. Without write access to the
  directory (not root), the install says the gate stays registered in user settings only and goes on.
- **The flag.** After deploying it runs `chattr +i` on each file in `hooks/`, `skills/ship` and `git-hooks`
  (recursively), `agents/ship-*.md`, `bin/shfmt`, the drop-in, `managed-settings.d` and the managed directory
  itself (so no other policy file can be added; the directory's other files are neither lifted nor flagged), then checks each with
  `lsattr`. A path that isn't flagged is a warning naming it, and makes the exit 1 when running as root (as another user the flag
  can't be set, which is no fault of the install). Without `chattr` or `lsattr` it warns once and goes on.
- **Reinstalls.** Before it writes anything (the `rm -rf` of `skills/ship` included), `install.sh` lifts the flag on every
  one of those paths that exists, and stops with nothing changed when one stays flagged (chattr needs root), so an
  install is never half done. Between runs only the user lifts a flag: `! chattr -i <path>`, then edit.
- **The order.** shfmt is fetched and run first, and then the template is validated, both before anything installed is
  touched: a gate without shfmt blocks every Bash call, and a failed fetch used to leave exactly that (#189).

Root can lift the flag and Claude's own commands run as the user, so this holds against a command Claude runs, not against
a root shell; a symlink or a filesystem without the flag is out of its reach too (see [Threat model](#threat-model)).

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
  a plain number of at least 1 blocks (a zero would reach `timeout` as no limit). A reviewer that times out (`timeout` exits 124) or fails blocks like any failure.

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
