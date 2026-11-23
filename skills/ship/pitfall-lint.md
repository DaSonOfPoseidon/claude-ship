# Pitfalls to lint rules

`docs/pitfalls.md` lists classes of bug past reviews caught. A few have a literal signature on one line (a GNU-only flag,
a leftover call) that the hygiene lint can flag the next time an agent writes it; most are behaviour, and no line-level
rule fits. This file is the procedure that links the two (claude-ship #313). It runs only in a repo where
`CLAUDE_AUTONOMOUS` is `true`, since the author commits. Elsewhere, only when the user asks.

## The ledger

An entry is a line of `docs/pitfalls.md` that starts `- **`, and its bold text is its title. The outcome for each entry is
recorded as a comment line at column 0 of `.github/claude-ship/lint` (the lint skips comments, so it needs no parser):

```
# pitfall: <bold title> -> <rule-id>[, <rule-id>]
# pitfall: <bold title> -> none: <short reason>
```

An entry is **pending** while no ledger line names its exact title. `~/.claude/hooks/pitfall-lint.sh pending [<dir>]`
prints the pending titles, one per line, reading the ledger from the checkout and from the default branch together. The
rules themselves come with their cases in `.github/claude-ship/lint-tests`, and `~/.claude/hooks/lint.sh check [--only <rule>]`
tests them (grammar: `~/.claude/hooks/lint-rules`). A rule from this procedure is always `warn`. A rule takes effect once it
is on the default branch, because the lint reads the project file from there.

The author is the `ship-lint-author` agent (`~/.claude/agents/ship-lint-author.md`, Haiku, in its own worktree). It decides
per title whether a rule fits, writes the `ban` lines, cases and ledger lines, proves them with `lint.sh check`, and commits on
a local branch without pushing. Its report has `branch:`, `worktree:`, `commits:`, a `rule:` or `none:` line per title and
`check: pass|fail`. Ship its branch only when `check` is `pass` and it reports a commit.

## A new pitfall

When an edit adds an entry to `docs/pitfalls.md`, the `pitfall-lint.sh hook` PostToolUse hook adds context that names the new
titles, the file's absolute path, the toplevel and the default branch. It asks once per session and entry, and it is silent
when the repo isn't opted in or the agent isn't installed. Follow it **without stopping the task you are on**:

1. Start a `ship-lint-author` in the background (`run_in_background: true`) with `source` (the file the hook names, not a
   copy: the new entry may not be on the default branch yet), `titles`, `toplevel`, `default branch` (and `base ref`),
   and `branch: lint/pitfall-<a short slug of the title>`. Several titles added by one edit go to one author.
2. Carry on. Don't wait for it, and don't let its branch into the task's PR: the rules ship as their own PR so the task's review
   stays about the task.
3. After the current task (its PR is pushed and reviewed), when the author has reported with `check: pass` and a commit, ship its
   branch as a PR of its own, through the ship skill's usual steps (`SKILL.md` steps 2 to 5: checks, push through the gate,
   Codex rounds), run from the `worktree:` the author reports. The title is the author's commit subject, and the body names
   the entries (no `Fixes`). Its ledger lines don't depend on the entry's own PR merging first: a ledger line for a title that
   isn't in the default branch's `docs/pitfalls.md` yet is ignored until it is.
4. If the author reports `check: fail`, no commit, or `stopped because:`, don't ship it: mention it in your report to the user.
   The entry stays pending, and the user can run a backfill later.

In orchestrated mode a `ship-implementer` doesn't start an author: when the hook advises it, the implementer puts the titles on
a `pitfalls:` line of its final report, and the orchestrator starts the author and queues its branch
(`orchestrate.md` step 4).

## Backfill

For a repo whose entries have no ledger lines yet (the bootstrap offers it once, `SKILL.md` step 1). Only in a repo with
`CLAUDE_AUTONOMOUS` `true`, and elsewhere only when the user asks.

1. List the queue: `~/.claude/hooks/pitfall-lint.sh pending <toplevel>`. Nothing printed means there is nothing to do.
2. Run authors **one at a time**, 8 titles each (the next 8 lines of the queue), all with `branch: lint/pitfall-backfill`
   and `source: <toplevel>/docs/pitfalls.md`. They share a branch, and a branch can be checked out in one worktree only: before
   the next author starts, remove the finished one's worktree (`git worktree list`, then `git worktree remove <path>`, never
   `--force`; `orchestrate.md` › Replacing an implementer, step 2). If git refuses because the worktree holds modified or
   untracked files, stop and ask: that is unfinished work. An author that stops, or reports `check: fail`, ends the backfill
   for you to look at; so does a title that is still pending after its batch.
3. Run the queue again after each batch, and stop when it prints nothing.
4. Ship `lint/pitfall-backfill` as **one PR**: `feat(lint): backfill lint rules from the existing pitfalls`, through the ship skill's
   usual steps (in orchestrated mode, `unit-state.sh lint/pitfall-backfill` shows `state: local <n>`; hand the branch to a
   `ship-implementer` with "continue from `local <n>`", as `orchestrate.md` › A unit with no report says). Its Codex fixes may
   narrow or drop a rule.
5. Never suppress a rule that hits the repo's own correct code: drop it (a `none` ledger line). If a batch wants an `error`-level
   rule, stop and ask the user.

When the PR merges, `pitfall-lint.sh pending` prints nothing and `lint.sh check` exits 0.
