# Orchestrated mode: Opus plans, Sonnet implements, one PR at a time

This file covers the GitHub loop. A workspace that opts in to local mode (or whose user asks for it) gets the
same cost model without the PR half: see **Local mode** at the end.

You (the main session) plan, triage and decide. Agents explore and implement, and the ship scripts do the
mechanics. Work gets done one PR at a time. This keeps each PR cheap, and keeps your context small enough to
plan well for a long time (claude-ship #66: over OBDCracker's first 5 PRs, the median cost per PR went from
$3.12 to $1.34).

## When it runs

| Repo variables | Session | What starts the loop |
|---|---|---|
| `CLAUDE_AUTONOMOUS` and `CLAUDE_ORCHESTRATE` both `true` | plan mode, given an objective | automatically: the `orchestrate-hint.sh` hook points here |
| `CLAUDE_AUTONOMOUS` `true`, `CLAUDE_ORCHESTRATE` not `true` | any | only when the user asks for it ("the PR loop", "work the ready issues one PR at a time") |
| `CLAUDE_AUTONOMOUS` not `true` | any | never: the ship skill's step 0 stops before any commit |
| none needed: the workspace's `AGENTS.md` or `CLAUDE.md` has `- mode: local` in its `## PR loop` section | plan mode, given an objective | automatically: the hook points to **Local mode** (below). The marker wins over the variables, so a git repo with it runs the local loop |
| no marker | any | only when the user asks for "the local loop" (any workspace, git or not) |

Only the user sets the variables (`! gh variable set CLAUDE_ORCHESTRATE --body true`). Without the loop, the
ship skill's steps run as usual, for one PR at a time in your own context.

## Who does what

Pro and Max usage limits are shared across models. Anthropic doesn't publish how much each model draws on
them, so API prices are the guide: per token, Opus costs about twice Sonnet, and Haiku about a twentieth of
Sonnet (for prompts up to 100k tokens). Your own turns cost the most, because every turn re-reads your whole
context. So delegate anything that doesn't need judgment, and take as few turns as you can.

| Work | Who | Model, effort |
|---|---|---|
| Choose and order the work, write plans, triage Codex, decide on merges | you | the session's (Opus) |
| Answer the plan's questions about the code | `ship-explorer` agent | Haiku, medium |
| A question the explorer marked "unsure" | `general-purpose` agent with `model: sonnet` | Sonnet |
| Implement a **normal** or **high-risk** unit, fix its gate and Codex findings | `ship-implementer` agent | Sonnet, high |
| Implement a unit in **Local mode** (no git, PR, gate or Codex), fix its failed checks and verification | `ship-local-implementer` agent | Sonnet, high |
| Implement a **trivial** unit (docs or config, no logic, ~20 lines) | `ship-implementer` with `model: haiku` | Haiku, high |
| Run a Codex round: request, wait, CI, list the findings, file the rule-decided issues and resolve the answered threads | `ship-codex` agent, started by the implementer after each push | Haiku, medium |
| The mechanics under it: wait, list, file issues | the ship scripts (`codex-wait.sh`, `codex-findings.sh`, `codex-triage.sh`, `p3-issue.sh`) | none |

- A trivial unit whose Haiku implementer the gate blocked twice goes to a new Sonnet `ship-implementer`
  (see **Replacing an implementer**).
- For a high-risk unit, spend your effort on the plan (more edge cases, exact TDD order, risk notes); don't
  implement it yourself.
- Never use Fable: it draws on a separate limit or on usage credits.

**Your own context.** Never read whole source files: the explorer's report is your view of the code. Read a
few lines yourself only to settle a gap. Pipe long command output through `tail` or `--jq`. Run waits in the
background (`run_in_background`) and get notified instead of polling.

## Repo settings

Read only `AGENTS.md` › `## PR loop`, if the repo has it. A missing setting takes its default:

| Setting | Default |
|---|---|
| checks | the check command in CLAUDE.md |
| ready label | `status:ready` |
| skip labels | none; also skip anything needing hardware, research or a design decision |
| priority labels | none: oldest first |
| merge | `no`: stop when a PR is ready and tell the user. `yes`: merge it yourself |

## State: GitHub, plus one plan file

Nothing about progress is kept locally. After `/clear` or compaction, work it out again:

| What | Where |
|---|---|
| plans | `$(git rev-parse --path-format=absolute --git-common-dir)/claude-ship/`: `loop.md` (a master plan from an objective) and `plan-<branch slug>.md` per unit. Shared by every worktree, outside the repo's files |
| queue | the master plan's units without a merged PR on their branch; else the open issues with the ready label minus the skip labels, by the priority labels in the order listed, then oldest first, unless the master plan orders them |
| in flight | your open PRs whose head branch is a planned unit's (`gh pr list --author @me --json number,headRefName`) |
| done | merged PRs on those branches |

The loop is built to keep going across automatic compaction, not only across `/clear`. After a summary, re-derive
the state as **Resuming** says before acting, including `ListAgents` for a live implementer or `ship-codex` agent,
and don't start a duplicate.

Delete a unit's plan file after its PR merges, and `loop.md` after the last unit.

## Planning (plan mode, from an objective)

1. Read `AGENTS.md` › Code Review Rules, `docs/pitfalls.md` and the `## PR loop` settings.
2. Explore with one `ship-explorer` call: a numbered list of tight questions (where X is, Y's signature, which
   tests cover Z, quote the lines that decide W). Not the built-in Explore, which runs on your model.
3. Split the objective into units of one PR each, small enough to review in one sitting, in dependency
   order. For each, write a section in the shape of `~/.claude/skills/ship/templates/plan.md`, with its tier.
4. Write this to the plan-mode plan file and ask for approval. Once approved, copy it to `loop.md`, write
   each unit's plan file, and start the loop. Don't ask again per PR.

Without an objective ("work the ready issues"), plan each issue as it comes up: step 2, then one plan file.

## The loop, per unit

1. **Pick** the next unit (or ready issue). Check that its issue is still open and still ready.
2. **Plan** it, if it has no plan file yet (above).
3. **Implement:** start a `ship-implementer` with the plan file's path, the default branch, and "open the PR
   and run the Codex rounds", plus `model: haiku` for a trivial unit. Keep its agent id for this PR. The
   implementer starts a `ship-codex` agent after each push, which requests the review, waits, reads CI and the
   findings, and applies the rule-decided outcomes (the ship skill's step 4 table: P3, and P2 in round 3, are
   filed as issues). The implementer reads each finding it is sent in full and judges it: it fixes the valid
   ones, answers the invalid ones with evidence, pushes, and starts the next round, up to 3 rounds. You are not
   in that loop: you wait for its final report.
4. **Read its report.** Its `codex:` line is the last round's outcome.
   - `clean`, with CI green: go to 6.
   - It stopped (`stopped because:`), or `codex:` is `stop`, `stalled`, `timeout`, `round-cap` or `error`:
     handle it as the stop table below says. A `stop:` line is a P0/P1 finding in round 3 or later: ask the
     user. `stalled` is Codex stalling (or never acknowledging a request) twice on one head: tell the user. `round-cap` and `timeout` need no new
     request unless the user asks.
   - `denied:` lines: the agent's triage write or call was denied, or `codex-triage.sh` failed part-way (auto
     mode denies subagents some calls, #100). `file:` names the triage file, `done:` the threads the script
     finished, and `denied:` quotes its `failed:` line (the thread and step that failed). A failed call may
     have done part of its work, so never rerun the file as it is. Read the file, remove the `done:` threads'
     entries, then check the failed thread for a half-applied reply or filed issue (its replies, and
     `gh issue list` for the finding), as the ship skill's step 4 says, and remove or adjust that entry too.
     Then run `~/.claude/skills/ship/codex-triage.sh <pr> <file>` once on what is left, from the implementer's
     worktree (`cd <worktree> && …`, since `p3-issue.sh` reads the branch). If the Write itself was denied and
     there is no file, write one from `codex-findings.sh` and the ship skill's step 4 table. You triage by hand
     only these.
   - `codex: not run (...)`: the implementer couldn't start `ship-codex` (nesting failed). Use the **fallback
     flow** below.
   - `codex: error` with `ship-codex` having ended early (its error says the wait was still running or was
     denied a `sleep`/`cat`, so no round was lost): the review is still going. This should no longer happen,
     since `ship-codex` now waits in the foreground and ends its turn only with its report (#142, #147). If it
     does, use the **fallback flow**'s wait yourself, and don't start another `ship-codex` or request again.
5. **Fallback flow (the implementer couldn't start `ship-codex`).** It requested round 1 and stopped. Then:
   - Run `~/.claude/skills/ship/codex-wait.sh <pr>` alone in a background command (nothing chained after it),
     with the exit codes as in the ship skill's step 3.4. Since your own checkout isn't on the PR's branch,
     check that the printed status names the PR's head (`gh pr view <pr> --json headRefOid -q .headRefOid`),
     not your HEAD, and to request again after exit 3 run, from the implementer's worktree,
     `cd <worktree> && ~/.claude/skills/ship/codex-round.sh <pr>` and only below 3
     `cd <worktree> && ~/.claude/skills/ship/codex-request.sh <pr> <slug> <head sha>`.
   - Triage with `codex-findings.sh` and the ship skill's step 4 table. **Not valid / file an issue:** write the
     entries to a JSON file with the Write tool and run `~/.claude/skills/ship/codex-triage.sh <pr> <file>`
     (format in the ship skill's step 4) from the worktree; it is yours to run since subagents can't resolve
     threads (#100). When the round also sends fixes, hold these entries and run the file once after the
     implementer's report, with its replied threads added as `resolve` entries.
   - **Fix:** send the findings, with thread ids and what each fix should be, to the same implementer
     (`SendMessage` to its id), adding "request the next round" only when `codex-round.sh <pr>` is below 3. If
     its id is gone (after `/clear`), replace it (see **Replacing an implementer**) and give the new one the
     plan file and the findings. The implementer only replies to its threads and doesn't resolve them (#100), so
     after its report add each thread its `replied:` lines list to the round's triage file as a
     `{"thread": "<id>", "outcome": "resolve"}` entry (one `codex-triage.sh` call for the whole round), before
     the next wait or recheck. The script ends with the status recheck, since the implementer's push ran while
     those threads were still open.
   - **Nothing to fix:** the script has already rechecked the status (`gh workflow run codex-review.yml`).

   Then wait again. Rounds are capped at 3 as in the ship skill.
6. **Done** when the ship skill's step 5 holds (CI, `codex-review`, any repo PR gate, pitfalls entries).
   - With `merge: yes`:
     1. Remove the implementer's worktree (as in **Replacing an implementer**, step 2). Git won't delete a
        branch that a worktree still has checked out.
     2. From your own checkout, run `gh pr merge <pr> --squash --delete-branch`. Always name the PR: without a
        number, gh merges the PR of the branch you're on, not the unit's.
     3. Move the issues it unblocked to the ready label, delete its plan file, and pull the default branch.
   - With `merge: no`: tell the user it's ready, then go on to the next unit only if it doesn't depend on
     this one.
7. **Tell the user in one line** what merged or is waiting, then go to 1. Don't suggest `/clear`: the harness
   compacts the context by itself, and the loop carries on across it (see **State**).

## Replacing an implementer

A new `ship-implementer` on an existing branch can't check it out while an earlier implementer's worktree still
has it. Worktrees share branches, so that worktree's commits are already on the local branch, pushed or not.
So before starting the new one, every time (an escalation, or a lost agent id after `/clear`):
1. Find the worktree that has the branch: `git worktree list`.
2. Remove it with `git worktree remove <path>`, never `--force`. Git refuses while the worktree has modified
   or untracked files; then stop and ask, since that's unfinished work. Ignored files (build output) are
   deleted with it.
3. Start the new implementer with the plan file's path. It picks up the local branch.

## Stop and ask the user

| Situation | Why |
|---|---|
| The work needs hardware, a car or device session, or a design decision | the user's call |
| A safety or policy change, or a gate finding you or the implementer judge wrong (a waiver) | only the user waives |
| A P0/P1 Codex finding in round 3 or later | the ship skill's outcome table |
| CI fails for a reason outside the PR, or Codex stalls twice on one head | not fixable in the PR |
| The implementer reports the plan is wrong, and fixing it changes what the user approved | re-approval |

Otherwise, keep going without asking.

## Resuming ("continue the PR loop")

1. Read `loop.md`, if there is one, and list the in-flight PRs.
2. Finish in-flight PRs first, picking each up at its state. Before starting any `ship-codex` or implementer
   for a PR, check `ListAgents` for a live `ship-codex` or implementer on that PR; if one exists, wait for it
   or `SendMessage` it instead of starting another (a duplicate `ship-codex` on #149 spent a round, #147):
   - no review requested yet, or a review pending: start a `ship-codex` agent directly (it does both: it
     requests only if no request for the head is out, then waits), with `pr`, `slug`, `sha` (the PR's head,
     `gh pr view <pr> --json headRefOid -q .headRefOid`), `worktree` (from `git worktree list`; if no
     worktree has the branch, replace the implementer first, see **Replacing an implementer**) and the triage
     file in both spellings (`$HOME/.claude/state/claude-ship/triage-<owner>+<repo>-<pr>.json`, and the same with
     `~` for `home`, as `agents/ship-codex.md` describes). A request already out for the head, even in round 3,
     is waited for, not refused. Its report's `fix:` lines go to the
     implementer, as in the fallback flow above
   - findings open: the head's latest review completed and left unresolved Codex threads. Tell it from a pending
     review yourself, before starting the agent: `gh pr view <pr> --json headRefOid,reviews` shows a review by
     `chatgpt-codex-connector` whose `commit.oid` is the head, and no `@codex review` comment on the PR
     (`gh pr view <pr> --json comments`) is newer than that review's `submittedAt`. A newer request means the
     review is pending, so use the first bullet. `ship-codex` does not check this in triage-only mode. Then start the same
     `ship-codex` with `mode: triage-only`. It requests and waits for nothing, takes the round from
     `codex-round.sh` as it is, lists the findings and applies the rule-decided outcomes. Normal mode here would
     post a new request (an answered request doesn't block one) and triage the findings a round too late, or
     return `round-cap` without reading them
   - green: done
3. Then take the queue.

## Local mode

For a workspace that isn't a GitHub repo (a local project, a data archive) or that opts out of the PR half. You
plan, `ship-explorer` explores (it needs no git), and Sonnet implements, one unit at a time. There is no PR, gate,
Codex, merge, label, issue or `CLAUDE_*` variable, and no commit: the changes stay in the working tree for the
user. A unit is done when its checks pass and, if the plan has a **Verify** field, the user has checked it by hand
(claude-ship #82). Only what the table below names changes; **Who does what**, **Your own context**, the
explore-then-split steps of **Planning** and **Stop and ask the user** apply as written.

| Topic | Local mode |
|---|---|
| Opt-in | `- mode: local` in the workspace's `AGENTS.md` or `CLAUDE.md`, inside `## PR loop` (backticks around `local` are fine), or the user asks for "the local loop". The workspace is the git toplevel if there is one, else the cwd |
| Settings | only `- checks:` from `## PR loop`, else the check command in CLAUDE.md; the ready, skip and priority labels and `merge` are ignored |
| State | `~/.claude/state/claude-ship/local/<slug>/`, where `<slug>` is the workspace's absolute path with `%` written `%25`, then `+` written `%2B`, then `/` written `+`, so no two paths share a directory (`/srv/CodeServer/MBSReporter` is `+srv+CodeServer+MBSReporter`; `/srv/a+b/c` is `+srv+a%2Bb+c`, `/srv/a/b+c` is `+srv+a+b%2Bc`). It holds `loop.md` and one `plan-<unit slug>.md` per unit. Nothing is kept in the workspace |
| `loop.md` | the master plan (the objective, then each unit's section in the shape of `templates/plan.md` with Branch, PR title and Commits left out and Issue(s) `none: from the objective`), then one status line per unit: `- [ ] unit N`, `- [~] unit N (implementing)`, `- [~] unit N (verifying)` or `- [x] unit N`. You edit the lines; the implementer never does |
| Queue and progress | the status lines of `loop.md`, in order, and nothing else: there are no issues or labels. Without `loop.md` there is no queue: plan from the user's objective |
| Planning | as above (one `ship-explorer` call, then split the objective into units small enough to implement and check in one go). Once the plan is approved, write `loop.md` with every unit `- [ ]` and one plan file per unit |
| Implement | start a `ship-local-implementer` with the plan file's path and the workspace directory. Set the unit to `- [~] unit N (implementing)` first. Keep its agent id. Start the next unit's implementer only when this one is `- [x]`: there are no worktrees, so two units would edit the same files |
| Done | read its report. `checks: pass` and no **Verify** field in the plan: set the unit `- [x]`. `checks: pass` and a **Verify** field: set `- [~] unit N (verifying)`, give the user the report's `verify:` steps, and stop until they answer. `checks: fail` or `stopped because:`: handle it as **Stop and ask the user** says, or send the failure to the same implementer |
| Verification result | the user says it works: `- [x]`. It fails: set `- [~] unit N (implementing)` and `SendMessage` the failure to the same implementer as a fix round; its next report goes through **Done** again. If its id is gone, start a new `ship-local-implementer` with the same plan file and the failure |
| After a unit | delete its plan file; after the last unit, delete `loop.md` and tell the user the changes are in the working tree, uncommitted. Then one line to the user, as in step 7 above |
| Resuming ("continue the local loop") | read `loop.md`. `- [x]` is done. `- [ ]` is next, once nothing is `~`. `- [~] (implementing)`: check `ListAgents` for a live implementer on that unit and wait for it or `SendMessage` it; if none is live, start a new `ship-local-implementer` with the same plan file and say the working tree may hold partial work to continue from, not redo. `- [~] (verifying)`: give the user the unit's **Verify** steps again and wait |
| Doesn't apply | the gate (no push), `ship-codex` and Codex rounds, PRs, merging, labels and issues, `ship-implementer`, worktrees, and **Replacing an implementer** |
