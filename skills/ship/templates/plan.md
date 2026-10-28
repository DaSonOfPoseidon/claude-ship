# Plan: <PR title>

<!-- One PR's plan, for the ship-implementer agent. In a master plan, each unit is a `## Unit <n>` section
     with these fields. Write facts from the explorer's report, not guesses. -->

- **Issue(s):** #N (or "none: from the objective")
- **Branch:** `fix/<N>-<slug>` / `feat/<slug>`
- **PR title:** `<type>(<scope>): <lower-case imperative>`, one line, under 72 characters
- **Tier:** trivial | normal | high-risk
  - trivial: docs or config with no logic, about 20 lines or fewer
  - high-risk: concurrency, security or safety policy, protocol state, data migration
- **Checks:** `<the repo's full check command>`

## Goal
What changes for the user or caller, in two or three sentences.

## Changes
For each file:
- `path`: the function or section, the behaviour it should end up with, and the callers it affects.

## Edge cases
The inputs and states the tests must cover: empty, 0, max, max+1, errors, the paths the change doesn't take.

## TDD order
1. Test `<name>` in `<file>`: what it asserts, and why it fails before the change.
2. The code change that makes it pass.
3. …

## Rules that apply
- The project invariants from AGENTS.md › Code Review Rules that this change touches.
- The pitfalls from `docs/pitfalls.md` to check, by name.
- The docs to keep in sync.

## Commits
1. `<subject>`: what goes in it.

## Risk notes
What the orchestrator worries about, and what the implementer should stop and report on rather than decide.
