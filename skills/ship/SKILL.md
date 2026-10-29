---
name: ship
description: Use when committing, pushing, opening a PR, or handling Codex review findings in a GitHub repo whose CLAUDE_AUTONOMOUS repo variable is true, or when bootstrapping a repo for autonomous commits. Runs the review → push → Codex round loop, capped at 3 rounds. Also covers orchestrated mode (Opus plans, Sonnet implements, one PR at a time): when the orchestrate-hint hook points to it in plan mode, or when the user asks for the PR loop.
---

# Ship: review → push → Codex, at most 3 rounds

The user's process (2026-10-19). It is built to keep each round cheap and to finish in at most 3 rounds.

**One round** = the pre-push gate passes → push → `@codex review` → triage. Codex runs only when asked
(automatic review is off), so never push "just to see": batch every fix into one push.

Scripts live next to this file: `~/.claude/skills/ship/`.

## Orchestrated mode (opt-in)

Read `orchestrate.md` next to this file, and follow it, only when:
- the `orchestrate-hint.sh` hook says orchestrated mode is on (plan mode, in a repo whose `CLAUDE_ORCHESTRATE`
  variable is `true`), or
- the user asks for the PR loop.

It runs the steps below one PR at a time, with agents doing the exploring and implementing. Otherwise
ignore it: the steps below are the whole process.

## 0. Is the repo opted in?

`gh variable get CLAUDE_AUTONOMOUS` (once per session):
- **Missing or not `true`:** don't commit or push without asking the user. Mention that they can opt in
  with `! gh variable set CLAUDE_AUTONOMOUS --body true`. Stop here.
- **`true`:** commit on your own (small, one logical step each, per the repo's conventions) and follow the
  rest of this skill. Only the user changes the variable.

## 1. Bootstrap (once, when AGENTS.md has no `## Code Review Rules`)

The gate blocks pushes until this exists. On a branch `chore/review-setup`:
1. Copy `templates/AGENTS.md` to `AGENTS.md` (or add its `## Code Review Rules` section to an existing
   one). Replace the invariants placeholder with the repo's real rules from CLAUDE.md, README and CI.
   Keep them short and repo-specific: what must never break, what input is untrusted, what must stay out
   of the repo.
2. Add a line `@AGENTS.md` to CLAUDE.md (create it if missing) so the rules aren't duplicated.
3. Copy `templates/codex-review.yml` to `.github/workflows/codex-review.yml`. It is a short caller (triggers
   and permissions) of claude-ship's reusable workflow (`DaSonOfPoseidon/claude-ship/.github/workflows/codex-status.yml@v1`),
   which holds the bot filter and concurrency and calls the action, so the repo keeps no copy of either the
   workflow body or the status script. Its check run is named `codex-review / codex-status`; the required
   `codex-review` status is set by the script. Lint it:
   `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7`.
4. Create `docs/pitfalls.md` if it doesn't exist, with the title `# Pitfalls` and this intro: "Classes of
   bug that reviews have caught here. Check every change against them, and add an entry when a review
   finds a new class." AGENTS.md's Known pitfalls section links to it, and the gate shows it to reviewers.
5. Create the label `review:p3` (`gh label create review:p3 --color c5def5 --description "Minor finding from an AI review"`).
   If the repo's issue conventions need more labels on auto-filed P3s, write the per-file label map
   `.github/claude-ship/p3-labels` (format in claude-ship's README; give every path an area and a `*` rule
   for priority and status, since the PR loop only picks up labeled issues) and ask the user to set the variables:
   `! gh variable set CLAUDE_P3_LABELS --body "review:p3,<more>"`, and optionally `CLAUDE_P3_TYPE_LABEL`
   (e.g. `bug`) and `CLAUDE_P3_MILESTONE` (`auto`).
6. Show the user the invariants you wrote, then ship the branch with the steps below.
7. After the bootstrap PR merges, ask the user before turning on branch protection that requires
   `codex-review` and the CI checks. It's outward-facing, so get an explicit yes first. Not before the
   merge: Codex reports a clean review by editing a comment, which runs the default branch's workflow, so
   the bootstrap PR itself never gets the status and couldn't merge.
8. Remind the user to turn off **Automatic review** for the repo in the Codex settings.

## 2. Before every push (local, no review tokens)

1. Run the repo's checks (CLAUDE.md lists them). Never push red.
2. Self-review the diff against `docs/pitfalls.md` and AGENTS.md › Code Review Rules.
3. **Class sweep:** for every fix, grep the branch's files (and the callers) for the same class of bug and
   fix all of them now. Codex flags one instance per round, so leftover siblings cost a round each.
4. Commit, then `git push`. The PreToolUse gate (`~/.claude/hooks/review-gate.sh`) reviews it:
   - Blocked: fix every blocking finding test-first, sweep, then push again (a re-push of the same commit
     re-blocks without a new review). If a finding is wrong, explain why and ask the user to waive it with
     `! ~/.claude/hooks/review-gate.sh --waive "<why>"`. Never work around the gate.
   - When a blocking finding is a new class of bug (no entry in `docs/pitfalls.md` covers it), add one in
     the same push: the class, what to check, and where it bit (PR or issue).
   - The gate files confirmed P3s as issues itself. Don't fix them in this PR.

## 3. Request the Codex round

1. Open the PR if there isn't one (Conventional Commit title, `Fixes #N` in the body, the repo's template).
2. `round=$(~/.claude/skills/ship/codex-round.sh <pr>)`. If it's already 3, don't request another; go to 5.
   If it fails, stop and fix the cause: a failed count isn't round 0.
3. `~/.claude/skills/ship/codex-request.sh <pr>` from the checkout that pushed (Bash timeout 300000). It
   waits until GitHub shows HEAD as the PR's head, then posts `@codex review`; posted earlier, Codex
   reviews the previous commit and the round is wasted. This is round `round+1`. If it fails, don't post
   the comment by hand: find out why the PR's head isn't HEAD. From any other checkout, name the commit
   instead: `codex-request.sh <pr> <owner/repo> <sha>` (the full SHA that was pushed) waits for that head,
   not for the checkout's HEAD. It is safe to repeat: when a request for that head is already out (after
   its push, unanswered, under 15 minutes old) it posts nothing and exits 0. In orchestrated mode a
   `ship-codex` agent runs steps 2 to 4 for the implementer (`orchestrate.md`).
4. Wait without polling turns: run `~/.claude/skills/ship/codex-wait.sh <pr>` alone in a background command
   (Bash `run_in_background`), with nothing chained after it: no `;`, `&&` or `|`. Anything chained after it
   delays the notification (a stall sat unnoticed on OBDCracker #208). Check CI separately once it exits.
   You're notified when it exits. It prints the status once it's no longer `pending` for HEAD, and exits 2
   on any error from `codex-status.sh` (fix that, don't retry blindly).
   - **Exit 3**: only a new request clears the status. Run step 3 again, once per HEAD. If that one ends in
     exit 3 too, stop and tell the user. A new request ends any earlier review, so old requests never need
     deleting. Exit 3 prints one of two statuses:
     - **"stalled"**: Codex's summary says running but hasn't changed in 15 min. Codex sometimes drops a
       review this way and never finishes it (openai/codex#55890, claude-ship #61). `codex-round.sh`
       doesn't count the stalled request, so the retry doesn't use a round.
     - **"finished more than once"**: a completion came that nobody asked for (an automatic review), so the
       status can't tell which one is the request's. The retry uses a round.
   - **Exit 1, timed out** after 20 min without a result or a stall: tell the user and don't request again.

   Before triage, check that the printed status names HEAD's SHA.

## 4. Triage

`~/.claude/skills/ship/codex-findings.sh <pr>` lists the unresolved threads compactly. Never dump the raw
comments API. For each finding, by priority and round:

| Priority | Rounds 1–2 | Round 3, and any later round the user allows |
|---|---|---|
| P0 / P1 | fix | **stop and ask the user**: fix or defer (a P0 is always fixed) |
| P2 | fix | file an issue |
| P3 and lower | file an issue | file an issue |

Every finding ends with one outcome (fixed, not valid, deferred to an issue, or out of scope → issue), and its
thread is resolved once it has one. A user-approved fix after round 3 gets one more review, with the same
right-hand column.

- **Not valid:** reply on the thread explaining why (with file:line evidence), then resolve it.
- **Fix:** test-first, with a sweep for the same class. Reply on the thread with the fixing commit, then
  resolve the thread.
- **File an issue:** reply on the thread with the issue's link, then resolve it. The issue is filed with
  `~/.claude/hooks/p3-issue.sh`, which applies the repo's labels and milestone the same way the gate does for
  its P3s.
- When a finding is a new class of bug (no entry in `docs/pitfalls.md` covers it), add one in the same push.

**Apply the outcomes in one call.** Write the triage to a JSON file in your scratchpad with the Write tool:
`[{"thread": "<id>", "outcome": "not-valid" | "issue" | "fixed" | "resolve", "reply": "<text>", "issue":
{"file": "<path>", "title": "<path>: <summary>", "body": "<finding>"}}]` (`issue` only for that outcome; `reply`
is not needed for `resolve`; thread ids as `codex-findings.sh` prints them). Then run
`~/.claude/skills/ship/codex-triage.sh <pr> <that file>` from the PR's checkout. For each entry it files the
issue (adding its link to the reply), posts the reply and resolves the thread; a `resolve` entry only resolves
the thread, for one that already has its reply (an implementer replied to it). Include a fixed thread only once
its fix is committed, so the reply can name the commit. It validates the whole file before any call and stops
at the first failure, naming the threads done: check that thread for a half-applied reply before rerunning
without the done ones.

Then:
- **Something was fixed:** go back to step 2 (the gate reviews only the new commits) and request the next
  round.
- **Nothing was fixed** (everything was filed or answered): the script has already run
  `gh workflow run codex-review.yml` so the status rechecks with the resolved threads. No new round is needed.

## 5. Done

The PR is ready for the user when CI is green, the `codex-review` status passes (on the bootstrap PR,
which can't get the status, `DRY_RUN=1 ~/.claude/skills/ship/codex-status.sh <pr>` prints `success` instead), and any repo PR gate
passes (OBDCracker: `scripts/pr-gate.sh`), and every new class of bug this PR's reviews found (gate or
Codex) has an entry in `docs/pitfalls.md`. Report the rounds used, the issues filed, and anything that
needed a decision. After round 3, never request another Codex review unless the user asks.

**Process docs** (review rules, contribution steps): when a review finds a gap in a rule, rewrite the whole
rule as one table or state list, then check every combination before pushing. Patching one sentence per
finding moves the gap somewhere else, and each move costs a round (OBDCracker #128 took 3 rounds that way).
