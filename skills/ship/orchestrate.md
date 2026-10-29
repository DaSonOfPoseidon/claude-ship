# Orchestrated mode: Opus plans, Sonnet implements, one PR at a time

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
| Implement a **trivial** unit (docs or config, no logic, ~20 lines) | `ship-implementer` with `model: haiku` | Haiku, high |
| Wait for Codex, list findings, file issues | the ship scripts (`codex-wait.sh`, `codex-findings.sh`, `p3-issue.sh`) | none |

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
   and request Codex round 1", plus `model: haiku` for a trivial unit. Keep its agent id for this PR.
4. **Read its report.**
   - If it stopped, handle the reason (table below).
   - Otherwise run `~/.claude/skills/ship/codex-wait.sh <pr>` alone in a background command (nothing
     chained after it), with the exit codes as in the ship skill's step 3.4. Two differences, since your own
     checkout isn't on the PR's branch:
     - Check that the printed status names the PR's head
       (`gh pr view <pr> --json headRefOid -q .headRefOid`), not your HEAD.
     - To request again after exit 3, run the ship skill's steps 3.2 and 3.3 from the implementer's worktree:
       `cd <worktree> && ~/.claude/skills/ship/codex-round.sh <pr>`, and only below 3,
       `cd <worktree> && ~/.claude/skills/ship/codex-request.sh <pr>`. The request compares the PR's head with
       the checkout's HEAD.
5. **Triage** with `codex-findings.sh` and the ship skill's step 4 outcome table:
   - **Not valid / file an issue:** do it yourself, in one call: write the entries to a JSON file with the
     Write tool and run `~/.claude/skills/ship/codex-triage.sh <pr> <file>` (format in the ship skill's step 4).
     It files the issues, replies and resolves. It is yours to run, not the implementer's: subagents can't
     resolve threads (#100). When the round also sends fixes, leave those threads out of the file (the
     implementer replies to them and you resolve them below); the status recheck the script then ends with is
     harmless, because the fix's push triggers the next one.
   - **Fix:** send the findings, with thread ids and what each fix should be, to the same implementer
     (`SendMessage` to its id), adding "request the next round" only when `codex-round.sh <pr>` is below 3.
     If its id is gone (after `/clear`), replace it
     (see **Replacing an implementer**), and give the new one the plan file and the findings.
     The implementer only replies to its threads; it doesn't resolve them (auto mode denies subagents that
     call, #100). So after its report, resolve each thread its `replied:` lines list (`resolveReviewThread`,
     with the thread id) before the next wait or recheck. A round where it stopped early resolves only the
     threads its `replied:` lines list, and threads it never replied to stay open.
   - **Nothing to fix:** the script has already rechecked the status (`gh workflow run codex-review.yml`).

   Then back to 4. Rounds are capped at 3 as in the ship skill.
6. **Done** when the ship skill's step 5 holds (CI, `codex-review`, any repo PR gate, pitfalls entries).
   - With `merge: yes`:
     1. Remove the implementer's worktree (as in **Replacing an implementer**, step 2). Git won't delete a
        branch that a worktree still has checked out.
     2. From your own checkout, run `gh pr merge <pr> --squash --delete-branch`. Always name the PR: without a
        number, gh merges the PR of the branch you're on, not the unit's.
     3. Move the issues it unblocked to the ready label, delete its plan file, and pull the default branch.
   - With `merge: no`: tell the user it's ready, then go on to the next unit only if it doesn't depend on
     this one.
7. **Tell the user in one line** what merged or is waiting, and that it's a good moment to `/clear` (resume
   with "continue the PR loop"). Then go to 1.

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
2. Finish in-flight PRs first, picking each up at its state:
   - no review requested yet: request one, from the worktree that has the branch (`git worktree list`), or
     through a new implementer if none does (see **Replacing an implementer**)
   - a review pending: wait for it
   - findings open: triage them
   - green: done
3. Then take the queue.
